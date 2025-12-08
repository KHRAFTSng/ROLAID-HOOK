// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AttestationRegistry} from "./AttestationRegistry.sol";
import {SettlementVault} from "./SettlementVault.sol";
import {OwnableLite} from "./OwnableLite.sol";

/// @notice Minimal AVS-facing auction task manager with attested settlement submissions.
contract AuctionService is OwnableLite {
    struct Auction {
        bytes32 oracleUpdateId;
        uint64 startTime;
        uint64 endTime;
        address winner;
        uint96 bidAmount;
        bytes32 settlementHash;
        bool settled;
    }

    AttestationRegistry public immutable attestationRegistry;
    SettlementVault public immutable settlementVault;

    uint256 public auctionCount;
    mapping(uint256 id => Auction) public auctions;

    uint64 public submissionGracePeriod = 10 minutes;

    event AuctionCreated(uint256 indexed id, bytes32 indexed oracleUpdateId, uint64 startTime, uint64 endTime);
    event SettlementSubmitted(
        uint256 indexed id,
        address indexed winner,
        uint96 bidAmount,
        bytes32 settlementHash,
        bytes32 appId,
        bytes32 imageDigest
    );

    constructor(address _attestationRegistry, address _settlementVault) {
        require(_attestationRegistry != address(0) && _settlementVault != address(0), "addr=0");
        attestationRegistry = AttestationRegistry(_attestationRegistry);
        settlementVault = SettlementVault(_settlementVault);
    }

    function setSubmissionGracePeriod(uint64 grace) external onlyOwner {
        submissionGracePeriod = grace;
    }

    function createAuction(bytes32 oracleUpdateId, uint64 startTime, uint64 endTime) external onlyOwner returns (uint256) {
        require(endTime > startTime, "bad window");

        auctionCount++;
        auctions[auctionCount] = Auction({
            oracleUpdateId: oracleUpdateId,
            startTime: startTime,
            endTime: endTime,
            winner: address(0),
            bidAmount: 0,
            settlementHash: bytes32(0),
            settled: false
        });

        emit AuctionCreated(auctionCount, oracleUpdateId, startTime, endTime);
        return auctionCount;
    }

    /// @notice Submit winning settlement with attested EigenCompute app proof.
    function submitSettlement(
        uint256 id,
        bytes32 appId,
        bytes32 imageDigest,
        address bidder,
        uint96 bidAmount,
        bytes calldata settlementData
    ) external {
        Auction storage a = auctions[id];
        require(a.endTime != 0, "unknown auction");
        require(!a.settled, "settled");
        require(block.timestamp >= a.startTime, "too early");
        require(block.timestamp <= a.endTime + submissionGracePeriod, "expired");
        require(attestationRegistry.verify(appId, imageDigest), "attest fail");
        require(bidder != address(0), "bidder=0");

        bytes32 settlementHash = keccak256(settlementData);

        a.winner = bidder;
        a.bidAmount = bidAmount;
        a.settlementHash = settlementHash;
        a.settled = true;

        settlementVault.recordProceeds(bidAmount);

        emit SettlementSubmitted(id, bidder, bidAmount, settlementHash, appId, imageDigest);
    }
}

