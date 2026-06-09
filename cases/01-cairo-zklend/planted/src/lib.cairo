// zklend_market — PLANTED twin for Atlas case 1 (zkLend, Feb 2025).
//
// Same-source twin of the CLEAN reference at ../clean/src/lib.cairo with the
// zkLend bug class planted. A `diff -r ../clean/src ../planted/src` shows
// the planted hunk explicitly: the empty-market guard and the dead-shares
// burn are absent here, and `donate` is permissionless.
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
//   to ZERO shares minted. The underlying is taken; the attacker
//   withdraws on their 1 share and pulls all the donated + truncated
//   amounts.
//
// Three pieces of clean defense are ABSENT below:
//
//   1. No MIN_INIT_DEPOSIT check on the empty-market path.
//   2. No dead-shares burn to a sentinel address.
//   3. No gate on `donate` — anyone can call it on any state with any
//      amount.
//
// The properties in tests/atlas_invariants.cairo (same file as clean/)
// fire on this twin:
//
//   A. accumulator monotonicity / empty-market guard — VIOLATED on
//      the 1-wei seed (post-state total_shares == 1 < MIN_INIT_SHARES).
//   B. round-trip non-amplification — VIOLATED on the attacker's
//      withdraw after the donate (withdrawn > deposited).
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
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    // Same constants the clean twin uses — kept in scope here so the
    // property file (which is identical between twins) can reference
    // them. The planted twin DOES NOT enforce them.
    const MIN_INIT_DEPOSIT: u256 = 1000_u256;
    const MIN_INIT_SHARES: u256 = 1000_u256;

    #[storage]
    struct Storage {
        total_assets: u256,
        total_shares: u256,
        shares: Map<ContractAddress, u256>,
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
        // PLANTED: on the empty market, accepts any amount > 0 and
        // mints `amount` shares 1:1 to the caller (no dead-shares
        // burn, no MIN_INIT_DEPOSIT check). On the non-empty path,
        // shares = amount * total_shares / total_assets — TRUNCATED
        // to 0 if amount * total_shares < total_assets. Both legs of
        // the bug class live in this one function.
        fn deposit(ref self: ContractState, amount: u256) -> u256 {
            assert!(amount > 0_u256, "amount must be > 0");
            let caller = get_caller_address();
            let assets = self.total_assets.read();
            let shares_total = self.total_shares.read();

            let shares_to_mint = if shares_total == 0_u256 {
                // PLANTED: empty market mints 1:1 with no minimum.
                // attacker's deposit(1) mints 1 share and bootstraps
                // the accumulator at 1; subsequent donate() inflates
                // it.
                amount
            } else {
                // PLANTED: TRUNCATING division; no `assert s > 0`.
                // Victim's deposit can mint zero shares while still
                // crediting total_assets += amount — the attacker
                // takes the inflated pool on withdraw.
                (amount * shares_total) / assets
            };

            let cur_shares = self.shares.read(caller);
            self.shares.write(caller, cur_shares + shares_to_mint);
            self.total_shares.write(shares_total + shares_to_mint);
            self.total_assets.write(assets + amount);

            let prev_deposited = self.deposited.read(caller);
            self.deposited.write(caller, prev_deposited + amount);

            shares_to_mint
        }

        // withdraw(shares) → assets_returned
        //
        // amount = shares * total_assets / total_shares. Same as the
        // clean twin. The withdraw path is not where the bug lives;
        // it is the extraction surface for the inflated accumulator.
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

        // donate(amount): permissionless. Credits `amount` to
        // total_assets without minting shares. PLANTED: no gate, no
        // cap. This is the flash-loan "donation" surface the attacker
        // used to inflate the accumulator.
        fn donate(ref self: ContractState, amount: u256) {
            assert!(amount > 0_u256, "amount must be > 0");
            let assets = self.total_assets.read();
            self.total_assets.write(assets + amount);
        }
    }
}
