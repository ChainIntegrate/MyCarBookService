// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev Test only: an account that behaves like a Universal Profile for these contracts. It validates
/// signatures with ERC-1271 (an ECDSA key with the SIGN permission, as LSP6 does), answers LSP6
/// permissions through `getData`, announces LSP0, and lets a key with CALL forward calls (`execute`).
contract MockUniversalProfile {
    uint256 internal constant SIGN = 0x200000;
    uint256 internal constant CALL = 0x800;
    bytes10 internal constant PERMISSIONS_PREFIX = 0x4b80742de2bf82acb363;

    mapping(address => uint256) public permissionsOf;

    constructor(address[] memory keys, uint256[] memory permissions) {
        for (uint256 i; i < keys.length; ++i) permissionsOf[keys[i]] = permissions[i];
    }

    function setPermissions(address key, uint256 permissions) external {
        require(permissionsOf[msg.sender] & 0x04 != 0, "not an administrator");
        permissionsOf[key] = permissions;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address key, ECDSA.RecoverError err) = ECDSA.tryRecover(hash, signature);
        if (err != ECDSA.RecoverError.NoError || permissionsOf[key] & SIGN == 0) return 0xffffffff;
        return 0x1626ba7e;
    }

    function getData(bytes32 dataKey) external view returns (bytes memory) {
        if (bytes10(dataKey) == PERMISSIONS_PREFIX) {
            address key = address(uint160(uint256(dataKey)));
            uint256 p = permissionsOf[key];
            return p == 0 ? new bytes(0) : abi.encodePacked(bytes32(p));
        }
        return new bytes(0);
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        require(permissionsOf[msg.sender] & CALL != 0, "no CALL permission");
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    /// @dev ERC-165 and LSP0 (ERC725Account), as a Universal Profile answers them (no LSP1: tokens are
    /// minted with `force`).
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x24871b3d;
    }
}
