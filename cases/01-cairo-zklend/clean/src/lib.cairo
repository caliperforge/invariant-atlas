// zklend_market — CLEAN twin for Atlas case 1 (zkLend, Feb 2025).
//
// Same-source twin of the vulnerable zkLend share-accounting market with
// the bug class corrected. The minimum-shares dead-mint at empty-market
// init + the rounding-in-protocol's-favor on share computation are the
// difference between this file and the `planted/` twin; everything else
// is byte-identical. A `diff -r ../clean/src ../planted/src` is the
// review surface for the planted-bug hunk.
//
// Bug class reconstructed (per BlockSec / Halborn / zkLend incident
// post-mortems, Feb 2025):
//
//   On an empty market, the share-accounting can be seeded by an
//   attacker for 1 wei (mints 1 share). The attacker then "donates"
//   a large quantity of the underlying directly to the market (via
//   flash loan) — inflating `total_assets` without minting shares.
//   The `lending_accumulator` (= total_assets / total_shares) is now
//   massively > 1. The attacker can then deposit a victim's amount
//   `d` that is less than the accumulator, and the deposit truncates
//   to ZERO shares minted (shares = d * total_shares / total_assets
//   rounds to 0 for d < total_assets / total_shares). The underlying
//   is taken; the attacker withdraws on their 1 share and pulls all
//   the donated + truncated amounts.
//
// Three properties detect this bug class on the planted twin and hold
// on this clean twin (driven by tests/atlas_invariants.cairo):
//
//   A. accumulator monotonicity / empty-market guard. The first deposit
//      that crosses `total_shares == 0` → `total_shares > 0` must mint
//      at least MIN_INIT_SHARES; donation on a not-yet-bootstrapped
//      market reverts.
//   B. round-trip conservation. For every user u, the value of u's
//      position never exceeds u's cumulative deposits less withdrawals
//      modulo at most 1 raw unit of floor-rounding slack per
//      round-trip.
//   C. precision-loss bound. A single deposit-then-withdraw round-trip
//      can give back at most `deposit`, never more.
//
// The clean fixes (the minimal hunks that diff against `planted/`):
//
//   1. `deposit` on empty market: amount must be >= MIN_INIT_DEPOSIT;
//      the first MIN_INIT_SHARES are minted to a locked sentinel
//      address (dead-shares pattern). This prevents the 1-wei seed.
//   2. `donate` on a not-yet-bootstrapped market reverts. Once
//      bootstrapped, the per-step donation is capped at
//      DONATE_RATIO_BPS of total_assets to bound the
//      accumulator's per-step delta.
//   3. Share calculation on non-empty deposit rounds DOWN (protocol's
//      favor); withdraw rounds DOWN on the asset return (protocol's
//      favor). This is unchanged from `planted/` because rounding
//      direction alone does not fix the bug — the empty-market guard
//      is what fixes the bug.
//
// License: Apache-2.0.

#[starknet::interface]
pub trait IZklendMarket<TContractState> {
    fn total_assets(self: @TContractState) -> u256;
    fn total_shares(self: @TContractState) -> u256;
    fn shares_of(self: @TContractState, who: starknet::ContractAddress) -> u256;
    fn deposited(self: @TContractState, who: starknet::ContractAddress) -> u256;
    fn withdrawn(self: @TContractState, who: starknet::ContractAddress) -> u256;

    fn deposit(ref self: TContractState, amount: u256) -> u256;
    fn withdraw(ref self: TContractState, shares: u256) -> u256;
    fn donate(ref self: TContractState, amount: u256);
}

#[starknet::contract]
pub mod ZklendMarket {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::contract_address_const;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    // Minimum initial deposit on the empty market; below this, the empty-
    // market path reverts. Sized to match the zkLend post-mortem's
    // "1-wei seed" attacker surface — any value >> 1 closes the seed.
    const MIN_INIT_DEPOSIT: u256 = 1000_u256;
    // Dead shares locked to the sentinel on first deposit. Combined with
    // MIN_INIT_DEPOSIT this is the Uniswap V2-style inflation-attack fix.
    const MIN_INIT_SHARES: u256 = 1000_u256;

    // Donation cap per step relative to current total_assets (in bps).
    // Bounds per-step accumulator delta on a bootstrapped market. The
    // sentinel attack would require a single-step donation that pushes
    // accumulator beyond any small user's deposit-truncation threshold;
    // capping per-step donation at 100% (10_000 bps) of current
    // total_assets bounds the per-step accumulator growth to ≤ 2x.
    const DONATE_RATIO_BPS: u256 = 10000_u256;
    const BPS_DENOM: u256 = 10000_u256;

    fn dead_sentinel() -> ContractAddress {
        contract_address_const::<0xDEAD>()
    }

    #[storage]
    struct Storage {
        total_assets: u256,
        total_shares: u256,
        shares: Map<ContractAddress, u256>,
        // Cumulative deposited and withdrawn per user, used by the
        // round-trip-conservation invariant in tests/. Tracked on-
        // chain so the invariant driver can read them without a side
        // ledger. Production zkLend does NOT need these; they are
        // here strictly for the property surface.
        deposited: Map<ContractAddress, u256>,
        withdrawn: Map<ContractAddress, u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.total_assets.write(0_u256);
        self.total_shares.write(0_u256);
    }

    #[abi(embed_v0)]
    impl ZklendMarketImpl of super::IZklendMarket<ContractState> {
        fn total_assets(self: @ContractState) -> u256 {
            self.total_assets.read()
        }

        fn total_shares(self: @ContractState) -> u256 {
            self.total_shares.read()
        }

        fn shares_of(self: @ContractState, who: ContractAddress) -> u256 {
            self.shares.read(who)
        }

        fn deposited(self: @ContractState, who: ContractAddress) -> u256 {
            self.deposited.read(who)
        }

        fn withdrawn(self: @ContractState, who: ContractAddress) -> u256 {
            self.withdrawn.read(who)
        }

        // deposit(amount) → shares_minted
        //
        // On the empty market, requires amount >= MIN_INIT_DEPOSIT and
        // mints MIN_INIT_SHARES to the dead sentinel before crediting
        // the caller. This is the CLEAN twin's load-bearing fix vs. the
        // zkLend bug class — the planted twin's empty-market path
        // accepts amount==1 and credits 1 share to the caller, which is
        // the inflation-seed.
        fn deposit(ref self: ContractState, amount: u256) -> u256 {
            assert!(amount > 0_u256, "amount must be > 0");
            let caller = get_caller_address();
            let assets = self.total_assets.read();
            let shares_total = self.total_shares.read();

            let shares_to_mint = if shares_total == 0_u256 {
                // Empty-market path: require MIN_INIT_DEPOSIT and burn
                // MIN_INIT_SHARES to the dead sentinel. The caller
                // receives (amount - MIN_INIT_SHARES) shares against the
                // (amount) assets they deposited; the sentinel takes
                // the remainder. After this step, total_shares ==
                // amount and total_assets == amount (1:1).
                assert!(amount >= MIN_INIT_DEPOSIT, "empty-market: amount < MIN_INIT_DEPOSIT");
                // Sentinel mint.
                self.shares.write(dead_sentinel(), MIN_INIT_SHARES);
                amount - MIN_INIT_SHARES
            } else {
                // Non-empty path: shares = amount * total_shares /
                // total_assets, rounded DOWN (protocol's favor).
                let s = (amount * shares_total) / assets;
                // The clean twin rejects truncate-to-zero deposits; the
                // depositor must mint at least one share. (The planted
                // twin omits this check — the bug class IS the empty-
                // market seed, but this gate is part of the canonical
                // fix and is included here so the clean leg holds the
                // round-trip property strictly.)
                assert!(s > 0_u256, "deposit would mint zero shares");
                s
            };

            let cur_shares = self.shares.read(caller);
            self.shares.write(caller, cur_shares + shares_to_mint);
            self.total_shares.write(shares_total + shares_to_mint
                + (if shares_total == 0_u256 { MIN_INIT_SHARES } else { 0_u256 }));
            self.total_assets.write(assets + amount);

            let prev_deposited = self.deposited.read(caller);
            self.deposited.write(caller, prev_deposited + amount);

            shares_to_mint
        }

        // withdraw(shares) → assets_returned
        //
        // amount = shares * total_assets / total_shares, rounded DOWN
        // (protocol's favor). Caller must own the shares.
        fn withdraw(ref self: ContractState, shares: u256) -> u256 {
            assert!(shares > 0_u256, "shares must be > 0");
            let caller = get_caller_address();
            let cur = self.shares.read(caller);
            assert!(cur >= shares, "insufficient shares");
            let assets = self.total_assets.read();
            let shares_total = self.total_shares.read();
            assert!(shares_total > 0_u256, "market empty");
            let amount = (shares * assets) / shares_total;

            self.shares.write(caller, cur - shares);
            self.total_shares.write(shares_total - shares);
            self.total_assets.write(assets - amount);

            let prev_withdrawn = self.withdrawn.read(caller);
            self.withdrawn.write(caller, prev_withdrawn + amount);

            amount
        }

        // donate(amount): credits `amount` to total_assets without
        // minting shares. Models the flash-loan "donation" path the
        // attacker used. On the clean twin: requires the market to be
        // bootstrapped (total_shares > 0) AND caps per-call donation
        // at DONATE_RATIO_BPS of total_assets to bound the per-step
        // accumulator delta.
        fn donate(ref self: ContractState, amount: u256) {
            assert!(amount > 0_u256, "amount must be > 0");
            let shares_total = self.total_shares.read();
            assert!(shares_total > 0_u256, "donate on empty market");
            let assets = self.total_assets.read();
            // Cap donation at DONATE_RATIO_BPS / BPS_DENOM of current
            // total_assets. With DONATE_RATIO_BPS=10000 the per-step
            // accumulator growth is bounded at ≤ 2x.
            let cap = (assets * DONATE_RATIO_BPS) / BPS_DENOM;
            assert!(amount <= cap, "donation exceeds per-step cap");
            self.total_assets.write(assets + amount);
        }
    }
}
