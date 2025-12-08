// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableLite} from "./OwnableLite.sol";

/// @notice Records proceeds split between LP vault and insurance vault destinations (native ETH).
contract SettlementVault is OwnableLite {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address payable public lpSink;
    address payable public insuranceSink;
    uint16 public lpShareBps; // remainder to insurance

    mapping(address caller => bool allowed) public isAuthorized;

    event SinksUpdated(address indexed lpSink, address indexed insuranceSink);
    event SplitUpdated(uint16 lpShareBps);
    event Authorized(address indexed caller, bool allowed);
    event ProceedsRecorded(uint256 amount, uint256 lpAmount, uint256 insuranceAmount);

    constructor(address payable _lpSink, address payable _insuranceSink, uint16 _lpShareBps) {
        require(_lpSink != address(0) && _insuranceSink != address(0), "sink=0");
        require(_lpShareBps <= BPS_DENOMINATOR, "bps>1");
        lpSink = _lpSink;
        insuranceSink = _insuranceSink;
        lpShareBps = _lpShareBps;
    }

    modifier onlyAuthorized() {
        require(isAuthorized[msg.sender], "not auth");
        _;
    }

    function setAuthorized(address caller, bool allowed) external onlyOwner {
        isAuthorized[caller] = allowed;
        emit Authorized(caller, allowed);
    }

    function setSinks(address payable _lpSink, address payable _insuranceSink) external onlyOwner {
        require(_lpSink != address(0) && _insuranceSink != address(0), "sink=0");
        lpSink = _lpSink;
        insuranceSink = _insuranceSink;
        emit SinksUpdated(_lpSink, _insuranceSink);
    }

    function setSplit(uint16 _lpShareBps) external onlyOwner {
        require(_lpShareBps <= BPS_DENOMINATOR, "bps>1");
        lpShareBps = _lpShareBps;
        emit SplitUpdated(_lpShareBps);
    }

    /// @notice Record proceeds and split native ETH according to lpShareBps.
    function recordProceeds(uint256 amount) external payable onlyAuthorized {
        require(msg.value == amount, "value!=amount");
        uint256 lpAmount = (amount * lpShareBps) / BPS_DENOMINATOR;
        uint256 insuranceAmount = amount - lpAmount;
        (bool s1, ) = lpSink.call{value: lpAmount}("");
        require(s1, "lp send fail");
        (bool s2, ) = insuranceSink.call{value: insuranceAmount}("");
        require(s2, "ins send fail");
        emit ProceedsRecorded(amount, lpAmount, insuranceAmount);
    }
}

