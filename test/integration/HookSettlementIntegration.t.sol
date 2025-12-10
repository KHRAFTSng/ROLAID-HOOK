// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {AttestationRegistry} from "../../src/avs/AttestationRegistry.sol";
import {SettlementVault} from "../../src/avs/SettlementVault.sol";
import {AuctionService} from "../../src/avs/AuctionService.sol";
import {LVRAuctionHook} from "../../src/LVRAuctionHook.sol";

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

contract HookSettlementIntegrationTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    IPoolManager poolManager = IPoolManager(address(1));
    address listener = address(0xBEEF);
    address payable lpSink = payable(address(0x1001));
    address payable insSink = payable(address(0x2002));

    HookHarness hook;
    AttestationRegistry registry;
    SettlementVault vault;
    AuctionService service;

    bytes32 constant APP_ID = keccak256("app-1");
    bytes32 constant DIGEST = keccak256("digest-1");

    function setUp() public {
        // Deploy hook with correct flags
        bytes memory constructorArgs = abi.encode(poolManager, listener);
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(HookHarness).creationCode, constructorArgs);
        hook = new HookHarness{salt: salt}(poolManager, listener);
        assertEq(address(hook), predicted);

        // Deploy AVS pieces
        registry = new AttestationRegistry();
        vault = new SettlementVault(lpSink, insSink, 7000); // 70/30 split
        service = new AuctionService(address(registry), address(vault));

        vault.setAuthorized(address(service), true);
        registry.setApp(APP_ID, DIGEST, true);
    }

    function testFullFlow_HookGatingAndSettlementSplit() public {
        // Authorize auction in hook
        hook.setAuctionService(address(this));
        PoolKey memory key = _poolKey();
        SwapParams memory params = _swapParams();
        bytes memory data = abi.encode("payload");

        hook.authorizeAuction(key, address(this), uint64(block.timestamp + 10), bytes32("oracle"));

        // Simulate swap gated by hook
        vm.recordLogs();
        hook.callBeforeSwap(address(this), key, params, data);
        hook.callAfterSwap(key, params, BalanceDeltaLibrary.ZERO_DELTA, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length > 0, "no logs");

        // Submit settlement through AuctionService (attested, payable)
        uint256 lpBefore = lpSink.balance;
        uint256 insBefore = insSink.balance;

        vm.deal(address(this), 1 ether);
        service.submitSettlement{value: 1 ether}(
            1, APP_ID, DIGEST, address(0xB1DD3), 1 ether, abi.encode("payload")
        );

        assertEq(lpSink.balance - lpBefore, (1 ether * 7000) / 10_000, "lp split");
        assertEq(insSink.balance - insBefore, 1 ether - ((1 ether * 7000) / 10_000), "ins split");
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        Currency c0 = Currency.wrap(address(0xAAA1));
        Currency c1 = Currency.wrap(address(0xAAA2));
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
    }

    function _swapParams() internal pure returns (SwapParams memory params) {
        params = SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: 0});
    }
}

