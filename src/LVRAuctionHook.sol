// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {OwnableLite} from "./avs/OwnableLite.sol";

/// @notice LVR-aware hook that surfaces swap activity for offchain/TEE auction logic.
/// Emits events downstream systems can subscribe to in order to kick off auctions.
/// Enforces that only the auction winner (authorized externally) can swap during its window.
contract LVRAuctionHook is BaseHook, OwnableLite {
    using PoolIdLibrary for PoolKey;

    /// @notice Offchain/TEE listener or dispatcher address (informational).
    address public immutable auctionListener;

    /// @notice Authorized auction service (onchain) that sets winners.
    address public auctionService;

    struct AuctionAccess {
        address winner;
        uint64 expiry;
        bytes32 oracleUpdateId;
    }

    mapping(PoolId => AuctionAccess) public access;

    event SwapObserved(PoolId indexed poolId, BalanceDelta delta, bytes32 payloadHash);
    event AuctionAuthorized(PoolId indexed poolId, address indexed winner, uint64 expiry, bytes32 oracleUpdateId);
    event AuctionRevoked(PoolId indexed poolId);
    event AuctionServiceSet(address indexed auctionService);

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
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Set the onchain auction service allowed to authorize winners.
    function setAuctionService(address service) external onlyOwner {
        require(service != address(0), "service=0");
        auctionService = service;
        emit AuctionServiceSet(service);
    }

    /// @notice Called by auctionService to authorize a winner for a pool until expiry.
    function authorizeAuction(PoolKey calldata key, address winner, uint64 expiry, bytes32 oracleUpdateId)
        external
    {
        require(msg.sender == auctionService, "not service");
        require(winner != address(0), "winner=0");
        require(expiry > block.timestamp, "expiry<=now");
        PoolId poolId = key.toId();
        access[poolId] = AuctionAccess({winner: winner, expiry: expiry, oracleUpdateId: oracleUpdateId});
        emit AuctionAuthorized(poolId, winner, expiry, oracleUpdateId);
    }

    /// @notice Revoke an active auction window.
    function revokeAuction(PoolKey calldata key) external {
        require(msg.sender == auctionService || msg.sender == owner, "not auth");
        PoolId poolId = key.toId();
        delete access[poolId];
        emit AuctionRevoked(poolId);
    }

    /// @dev Enforce only the authorized winner can swap before expiry.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        AuctionAccess memory a = access[poolId];
        require(a.winner != address(0), "auction:inactive");
        require(block.timestamp <= a.expiry, "auction:expired");
        require(sender == a.winner, "auction:unauthorized");
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
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

