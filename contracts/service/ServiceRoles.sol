// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ServiceRoles
/// @notice The role of a business register, written by ChainIntegrate when it creates the register
/// (docs/DESIGN.md §3.2). Public: it is what gives an attestation its weight.
library ServiceRoles {
    uint8 internal constant WORKSHOP = 1;
    uint8 internal constant BODY_SHOP = 2;
    uint8 internal constant TYRE_SHOP = 3;
    uint8 internal constant DEALER = 4;
    uint8 internal constant MANUFACTURER = 5;
    uint8 internal constant FLEET = 6;
    uint8 internal constant INSPECTION_CENTRE = 7;

    uint8 internal constant MAX_ROLE = 7;

    function isValid(uint8 role) internal pure returns (bool) {
        return role >= WORKSHOP && role <= MAX_ROLE;
    }

    /// @notice Roles that may issue a verified vehicle token (docs/DESIGN.md §4.2).
    function canIssueVehicles(uint8 role) internal pure returns (bool) {
        return role == DEALER || role == MANUFACTURER;
    }
}
