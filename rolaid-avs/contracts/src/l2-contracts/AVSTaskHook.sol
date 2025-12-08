// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IAVSTaskHook} from "@eigenlayer-contracts/src/contracts/interfaces/IAVSTaskHook.sol";
import {ITaskMailboxTypes} from "@eigenlayer-contracts/src/contracts/interfaces/ITaskMailbox.sol";

contract AVSTaskHook is IAVSTaskHook {
    function validatePreTaskCreation(
        address, /*caller*/
        ITaskMailboxTypes.TaskParams memory /*taskParams*/
    ) external view {
        // Accept all tasks by default; customize for LVR/insurance constraints if needed.
    }

    function handlePostTaskCreation(
        bytes32 /*taskHash*/
    ) external {
        // No-op hook; extend to emit signals or route to offchain auctioneer if desired.
    }

    function validatePreTaskResultSubmission(
        address, /*caller*/
        bytes32, /*taskHash*/
        bytes memory, /*cert*/
        bytes memory /*result*/
    ) external view {
        // Accept all result submissions by default; add checks when wiring task semantics.
    }

    function handlePostTaskResultSubmission(
        address, /*caller*/
        bytes32 /*taskHash*/
    ) external {
        // No-op hook; extend to update state or emit events.
    }

    function calculateTaskFee(
        ITaskMailboxTypes.TaskParams memory /*taskParams*/
    ) external view returns (uint96) {
        // No task fee charged by default.
        return 0;
    }
}
