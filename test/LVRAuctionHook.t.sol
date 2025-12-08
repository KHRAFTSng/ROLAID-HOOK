// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LVRAuctionHook} from "../src/LVRAuctionHook.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

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
}

contract LVRAuctionHookTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    IPoolManager poolManager = IPoolManager(address(1));
    address listener = address(0xBEEF);

    HookHarness hook;

    function setUp() public {
        bytes memory constructorArgs = abi.encode(poolManager, listener);
        uint160 flags = Hooks.AFTER_SWAP_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(HookHarness).creationCode, constructorArgs);

        hook = new HookHarness{salt: salt}(poolManager, listener);
        assertEq(address(hook), predicted);
    }

    function testPermissions() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeSwap);
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

        vm.expectEmit(true, false, false, true);
        emit LVRAuctionHook.SwapObserved(key.toId(), delta, keccak256(data));
        hook.callAfterSwap(key, params, delta, data);
    }
}

