// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LVRAuctionHook} from "../src/LVRAuctionHook.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

contract HookHarness is LVRAuctionHook {
    constructor(IPoolManager pm, address listener) LVRAuctionHook(pm, listener) {}

    function callAfterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external returns (bytes4, int128) {
        return _afterSwap(msg.sender, key, params, delta, data);
    }

    function callBeforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata data
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, params, data);
    }
}

contract LVRAuctionHookTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    IPoolManager poolManager = IPoolManager(address(1));
    address listener = address(0xBEEF);

    HookHarness hook;

    function setUp() public {
        bytes memory constructorArgs = abi.encode(poolManager, listener);
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(HookHarness).creationCode, constructorArgs);

        hook = new HookHarness{salt: salt}(poolManager, listener);
        assertEq(address(hook), predicted);
    }

    function testPermissions() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
    }

    function testConstructorStoresListener() public {
        assertEq(hook.auctionListener(), listener);
        assertEq(address(hook.poolManager()), address(poolManager));
    }

    function testAfterSwapEmitsEvent() public {
        // Construct minimal PoolKey
        Currency c0 = Currency.wrap(address(0xAAA1));
        Currency c1 = Currency.wrap(address(0xAAA2));
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 100,
            sqrtPriceLimitX96: 0
        });

        BalanceDelta delta = BalanceDeltaLibrary.ZERO_DELTA;
        bytes memory data = abi.encode("payload");

        // authorize auction first
        hook.setAuctionService(address(this));
        hook.authorizeAuction(key, address(this), uint64(block.timestamp + 10), bytes32("oracle"));

        // need to go through beforeSwap gating
        vm.recordLogs();
        hook.callBeforeSwap(address(this), key, params, data);
        hook.callAfterSwap(key, params, delta, data);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // last log should be SwapObserved
        Vm.Log memory l = logs[logs.length - 1];
        bytes32 poolId = l.topics[1];
        (BalanceDelta emittedDelta, bytes32 phash) = abi.decode(l.data, (BalanceDelta, bytes32));
        bytes32 expectedPoolId;
        assembly {
            // poolKey memory layout (5 slots)
            expectedPoolId := keccak256(key, 0xa0)
        }
        assertEq(poolId, expectedPoolId);
        assertEq(BalanceDelta.unwrap(emittedDelta), BalanceDelta.unwrap(delta));
        assertEq(phash, keccak256(data));
    }

    function testBeforeSwapRequiresWinnerAndNotExpired() public {
        Currency c0 = Currency.wrap(address(0xAAA1));
        Currency c1 = Currency.wrap(address(0xAAA2));
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 100,
            sqrtPriceLimitX96: 0
        });
        bytes memory data = abi.encode("payload");

        vm.expectRevert("auction:inactive");
        hook.callBeforeSwap(address(this), key, params, data);

        hook.setAuctionService(address(this));
        hook.authorizeAuction(key, address(0xB1D), uint64(block.timestamp + 1), bytes32("o"));

        vm.expectRevert("auction:unauthorized");
        hook.callBeforeSwap(address(this), key, params, data);

        vm.warp(block.timestamp + 2);
        vm.expectRevert("auction:expired");
        hook.callBeforeSwap(address(0xB1D), key, params, data);
    }
}

