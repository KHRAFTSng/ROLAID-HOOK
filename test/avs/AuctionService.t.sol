// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {AttestationRegistry} from "../../src/avs/AttestationRegistry.sol";
import {SettlementVault} from "../../src/avs/SettlementVault.sol";
import {AuctionService} from "../../src/avs/AuctionService.sol";

contract AuctionServiceTest is Test {
    AttestationRegistry registry;
    SettlementVault vault;
    AuctionService service;

    bytes32 constant APP_ID = keccak256("app-1");
    bytes32 constant DIGEST = keccak256("digest-1");
    address payable lpSink = payable(address(0x1000));
    address payable insSink = payable(address(0x2000));

    function setUp() public {
        registry = new AttestationRegistry();
        vault = new SettlementVault(lpSink, insSink, 7000); // 70/30 split
        service = new AuctionService(address(registry), address(vault));

        vault.setAuthorized(address(service), true);
        registry.setApp(APP_ID, DIGEST, true);
    }

    function testCreateAuction() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = startTime + 1 hours;

        uint256 id = service.createAuction(bytes32("oracle-1"), startTime, endTime);

        assertEq(id, 1);
        (bytes32 oracleId, uint64 start, uint64 end, address winner, uint96 bid, bytes32 hash, bool settled) =
            service.auctions(id);

        assertEq(oracleId, bytes32("oracle-1"));
        assertEq(start, startTime);
        assertEq(end, endTime);
        assertEq(winner, address(0));
        assertEq(bid, 0);
        assertEq(hash, bytes32(0));
        assertFalse(settled);
    }

    function testSubmitSettlement() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = startTime + 1 hours;
        uint256 id = service.createAuction(bytes32("oracle-1"), startTime, endTime);

        bytes memory settlementData = abi.encode("payload");
        vm.warp(endTime - 1); // within auction window

        uint256 lpBefore = lpSink.balance;
        uint256 insBefore = insSink.balance;

        service.submitSettlement{value: 1 ether}(id, APP_ID, DIGEST, address(0xB1DD3), 1 ether, settlementData);

        (, , , address winner, uint96 bidAmount, bytes32 settlementHash, bool settled) = service.auctions(id);
        assertEq(winner, address(0xB1DD3));
        assertEq(bidAmount, 1 ether);
        assertEq(settlementHash, keccak256(settlementData));
        assertTrue(settled);

        assertEq(lpSink.balance - lpBefore, (1 ether * 7000) / 10_000);
        assertEq(insSink.balance - insBefore, 1 ether - ((1 ether * 7000) / 10_000));
    }

    function testRevertsWithoutAttestation() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = startTime + 1 hours;
        uint256 id = service.createAuction(bytes32("oracle-1"), startTime, endTime);

        bytes memory settlementData = abi.encode("payload");
        vm.warp(endTime - 1);

        vm.expectRevert(bytes("attest fail"));
        service.submitSettlement{value: 1 ether}(id, APP_ID, keccak256("wrong"), address(0xB1DD3), 1 ether, settlementData);
    }
}

