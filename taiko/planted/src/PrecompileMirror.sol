// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title PrecompileMirror (PLANTED twin) - Taiko execution-layer mirror for canonical L1 precompiles.
///
/// Type-1 Ethereum-equivalence requires that the rollup execution client
/// return byte-identical output to L1 for every precompile invocation on
/// every input. The Atlas does NOT vendor Taiko's execution client. The
/// mirror is the smallest contract that exposes the precompile surface
/// the way an application sees it: input bytes in, output bytes out.
///
/// Twin shape: the CLEAN mirror is a direct passthrough to the canonical
/// L1 precompile address. The PLANTED twin (under `planted/`) introduces a
/// localized divergence - the same single-hunk discipline used everywhere
/// in the Atlas - which the differential harness in `test/` detects as
/// "the mirror disagrees with L1."
///
/// Precompile chosen: SHA256 (`0x02`). SHA256 is the simplest to vector-test
/// (RFC 6234 / NIST FIPS 180-4 test vectors are public and one-shot), and
/// SHA256 equivalence is implied verbatim by Type-1 - a rollup that drifts
/// on SHA256 cannot run L1's pre-compiled cryptography stack at all.
///
/// Reference: Taiko whitepaper §"Ethereum-equivalence" + Ethereum Yellow
/// Paper Appendix E (precompiled contracts). Cited in README.
contract PrecompileMirror {
    address internal constant SHA256_PRECOMPILE = address(0x2);

    /// @notice Mirror SHA256(input) the way a Type-1 rollup execution
    ///         client must: byte-identical output to L1.
    function sha256Mirrored(bytes memory input) external view returns (bytes32 out) {
        (bool ok, bytes memory ret) = SHA256_PRECOMPILE.staticcall(input);
        require(ok, "sha256 precompile call failed");
        require(ret.length == 32, "sha256 precompile MUST return 32 bytes");
        // PLANTED: XOR-mask the highest byte. Real bug class is an
        // execution-client byte-ordering or endianness mismatch that flips
        // a single byte and survives every happy-path test that does not
        // compare against L1.
        out = bytes32(ret) ^ bytes32(uint256(0x01) << 248);
    }
}
