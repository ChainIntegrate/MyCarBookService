// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What `VehicleRegistry` and `ServiceRegistry` read from the factory.
interface IServiceRegistryFactory {
    function isRegistry(address registry) external view returns (bool);

    function roleOf(address registry) external view returns (uint8);

    function isActive(address registry) external view returns (bool);

    function vehicleRegistry() external view returns (address);
}

/// @notice What a business register calls on the vehicle registry (dealers and manufacturers).
interface IVehicleRegistry {
    function issueVerified(
        bytes32 vehicleId,
        bytes32 contentHash,
        bytes calldata recordRef
    ) external returns (bytes32 tokenId);
}

/// @notice The owner of a business register (to mint a verified vehicle to it).
interface IOwnedRegistry {
    function owner() external view returns (address);
}

/// @notice ERC725Y read access, to check a Universal Profile's LSP6 permissions.
interface IERC725YReader {
    function getData(bytes32 dataKey) external view returns (bytes memory);
}
