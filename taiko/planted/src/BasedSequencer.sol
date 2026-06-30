// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title BasedSequencer - Taiko based-sequencing ordering mirror.
///
/// PLANTED-TWIN VARIANT. See `clean/src/BasedSequencer.sol` for the full
/// header. The planted hunk reorders the inclusion list by priority fee
/// descending at finalize() time - the canonical "sequencer reorder for
/// MEV" violation which based-sequencing is supposed to prevent. The bug
/// is invisible if the proposer happens to send tx in priority-fee
/// descending order anyway; the differential harness exercises an
/// adversarial ordering to surface it.
contract BasedSequencer {
    struct ProposedTx {
        bytes32 txHash;
        uint256 priorityFee;
    }

    ProposedTx[] internal queue;
    bool internal finalized;

    function propose(bytes32 txHash, uint256 priorityFee) external {
        require(!finalized, "already finalized");
        queue.push(ProposedTx({txHash: txHash, priorityFee: priorityFee}));
    }

    function finalize() external returns (bytes32[] memory order) {
        require(!finalized, "already finalized");
        finalized = true;
        // Planted bug: sort by priorityFee descending. An honest based
        // proposer MUST preserve insertion order. Sorting by priority fee
        // is the classic MEV-extracting reorder.
        ProposedTx[] memory sorted = new ProposedTx[](queue.length);
        for (uint256 i = 0; i < queue.length; i++) {
            sorted[i] = queue[i];
        }
        for (uint256 i = 0; i < sorted.length; i++) {
            for (uint256 j = i + 1; j < sorted.length; j++) {
                if (sorted[j].priorityFee > sorted[i].priorityFee) {
                    ProposedTx memory tmp = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = tmp;
                }
            }
        }
        order = new bytes32[](sorted.length);
        for (uint256 i = 0; i < sorted.length; i++) {
            order[i] = sorted[i].txHash;
        }
    }

    function queueLength() external view returns (uint256) {
        return queue.length;
    }
}
