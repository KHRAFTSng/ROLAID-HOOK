// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice LVR-aware hook that surfaces swap activity for offchain/TEE auction logic.
/// Emits events downstream systems can subscribe to in order to kick off auctions.
contract LVRAuctionHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Offchain/TEE listener or dispatcher address (informational).
    address public immutable auctionListener;

    event SwapObserved(PoolId indexed poolId, BalanceDelta delta, bytes32 payloadHash);

    constructor(IPoolManager _poolManager, address _auctionListener) BaseHook(_poolManager) {
        auctionListener = _auctionListener;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Emits an event with swap deltas; does not modify swap behavior.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata data
    ) internal override returns (bytes4, int128) {
        emit SwapObserved(key.toId(), delta, keccak256(data));
        return (BaseHook.afterSwap.selector, 0);
    }
}

