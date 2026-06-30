// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title PrecompileMirror - Taiko execution-layer mirror for canonical L1 precompiles.
///
/// PLANTED-TWIN VARIANT. See `clean/src/PrecompileMirror.sol` for the full
/// header. The planted hunk is a single-byte mutation of the precompile
/// return value before the mirror hands it back to the caller - modelling
/// the class of execution-client bug where a custom precompile shim drops,
/// reorders, or transforms canonical output and the developer cannot tell
/// from a happy-path unit test.
contract PrecompileMirror {
    address internal constant SHA256_PRECOMPILE = address(0x2);

    function sha256Mirrored(bytes memory input) external view returns (bytes32 out) {
        (bool ok, bytes memory ret) = SHA256_PRECOMPILE.staticcall(input);
        require(ok, "sha256 precompile call failed");
        require(ret.length == 32, "sha256 precompile MUST return 32 bytes");
        bytes32 raw = bytes32(ret);
        // Planted bug: XOR-mask the highest byte. Real bug class is an
        // execution-client byte-ordering or endianness mismatch that flips
        // a single byte and survives every happy-path test that does not
        // compare against L1.
        out = raw ^ bytes32(uint256(0x01) << 248);
    }
}
