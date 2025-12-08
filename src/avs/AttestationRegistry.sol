// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableLite} from "./OwnableLite.sol";

/// @notice Records allowed EigenCompute app IDs and image digests for attested submissions.
contract AttestationRegistry is OwnableLite {
    struct AppRecord {
        bytes32 imageDigest;
        bool active;
    }

    mapping(bytes32 appId => AppRecord) public apps;

    event AppSet(bytes32 indexed appId, bytes32 indexed imageDigest, bool active);

    function setApp(bytes32 appId, bytes32 imageDigest, bool active) external onlyOwner {
        apps[appId] = AppRecord({imageDigest: imageDigest, active: active});
        emit AppSet(appId, imageDigest, active);
    }

    function verify(bytes32 appId, bytes32 imageDigest) external view returns (bool) {
        AppRecord memory rec = apps[appId];
        return rec.active && rec.imageDigest == imageDigest;
    }
}

