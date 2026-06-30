// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title BasedSequencer - Taiko based-sequencing ordering mirror.
///
/// Taiko's based-sequencing rule: L2 blocks land in proposal order. The
/// proposer is whoever included the L2 block on L1 first, and the prover
/// (separate role) does NOT reorder. This is the bedrock guarantee that
/// distinguishes a based rollup from a "rollup-with-sequencer-MEV-extraction"
/// design - a proposer or prover that quietly sorts the block by priority
/// fee descending IS a Taiko spec violation.
///
/// The Atlas does NOT model the on-chain proposer auction or the prover
/// market. The mirror exposes the ONE invariant that downstream apps rely
/// on: the order an inclusion list is finalized in IS the order proposals
/// arrived. Any contract that exposes a `propose -> finalize` shape and
/// claims based-sequencing semantics MUST hold this invariant.
///
/// Twin shape: CLEAN mirror appends to the inclusion list in insertion
/// order. PLANTED twin sorts the list by priority fee descending at
/// `finalize()` time - the canonical "sequencer reorder for MEV" bug
/// class which based-sequencing is supposed to make impossible.
///
/// Reference: Taiko whitepaper §"Based contestable rollup", §"Proposing
/// and proving". Cited in README.
contract BasedSequencer {
    struct ProposedTx {
        bytes32 txHash;
        uint256 priorityFee;
    }

    ProposedTx[] internal queue;
    bool internal finalized;

    /// @notice A proposer appends a tx to the inclusion list.
    /// @dev `priorityFee` is recorded but MUST NOT be used to reorder.
    function propose(bytes32 txHash, uint256 priorityFee) external {
        require(!finalized, "already finalized");
        queue.push(ProposedTx({txHash: txHash, priorityFee: priorityFee}));
    }

    /// @notice Finalize the inclusion list. Returns the canonical order
    ///         the prover MUST attest to.
    /// @dev Clean leg: returns the queue verbatim - insertion order.
    function finalize() external returns (bytes32[] memory order) {
        require(!finalized, "already finalized");
        finalized = true;
        order = new bytes32[](queue.length);
        for (uint256 i = 0; i < queue.length; i++) {
            order[i] = queue[i].txHash;
        }
    }

    function queueLength() external view returns (uint256) {
        return queue.length;
    }
}
