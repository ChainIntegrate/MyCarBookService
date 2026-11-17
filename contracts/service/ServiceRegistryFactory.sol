// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ServiceRegistry} from "./ServiceRegistry.sol";
import {ServiceRoles} from "./ServiceRoles.sol";

/// @title ServiceRegistryFactory
/// @notice Creates one `ServiceRegistry` per business (the "MyCarBook Service authorization",
/// docs/DESIGN.md §3) as an EIP-1167 clone of a single implementation, with the business's role.
/// The factory's owner (ChainIntegrate) decides who gets a register and may mark a register suspended;
/// it has no rights inside a register. Suspension does not change a register: the relayer and the
/// backend stop serving it, the vehicle registry refuses its vehicle issuance, and readers see since when.
contract ServiceRegistryFactory is Ownable {
    /// @notice The register implementation every clone delegates to.
    address public immutable implementation;

    /// @notice The vehicle registry registers issue vehicles to (set once, after both are deployed).
    address public vehicleRegistry;

    /// @notice True for every register this factory created.
    mapping(address => bool) public isRegistry;
    /// @notice The role written at creation (`ServiceRoles`).
    mapping(address => uint8) public roleOf;
    /// @notice Time the register was suspended, or 0 when active.
    mapping(address => uint64) public suspendedSince;

    address[] private _registries;

    event RegistryCreated(address indexed registry, address indexed owner, uint8 indexed role, string name);
    event RegistrySuspended(address indexed registry, uint64 since);
    event RegistryReactivated(address indexed registry);
    event VehicleRegistrySet(address indexed vehicleRegistry);

    error InvalidOwner();
    error InvalidRole(uint8 role);
    error UnknownRegistry(address registry);
    error StatusUnchanged(address registry);
    error VehicleRegistryAlreadySet();
    error InvalidVehicleRegistry();
    error RenounceDisabled();

    constructor(address initialOwner) {
        implementation = address(new ServiceRegistry());
        _transferOwnership(initialOwner);
    }

    /// @notice Sets the vehicle registry, once.
    function setVehicleRegistry(address registry_) external onlyOwner {
        if (vehicleRegistry != address(0)) revert VehicleRegistryAlreadySet();
        if (registry_ == address(0) || registry_.code.length == 0) revert InvalidVehicleRegistry();
        vehicleRegistry = registry_;
        emit VehicleRegistrySet(registry_);
    }

    /// @notice Creates a register owned by `registryOwner` (the business's account), at
    /// `predictRegistryAddress(salt)`.
    function createRegistry(
        bytes32 salt,
        address registryOwner,
        uint8 role,
        string calldata name,
        string calldata symbol
    ) external onlyOwner returns (address registry) {
        if (registryOwner == address(0)) revert InvalidOwner();
        if (!ServiceRoles.isValid(role)) revert InvalidRole(role);
        registry = Clones.cloneDeterministic(implementation, salt);
        ServiceRegistry(payable(registry)).initialize(name, symbol, registryOwner, role);
        isRegistry[registry] = true;
        roleOf[registry] = role;
        _registries.push(registry);
        emit RegistryCreated(registry, registryOwner, role, name);
    }

    /// @notice Marks a register suspended (`true`) or active again (`false`).
    function setSuspended(address registry, bool suspended) external onlyOwner {
        if (!isRegistry[registry]) revert UnknownRegistry(registry);
        bool current = suspendedSince[registry] != 0;
        if (current == suspended) revert StatusUnchanged(registry);
        if (suspended) {
            uint64 since = uint64(block.timestamp);
            suspendedSince[registry] = since;
            emit RegistrySuspended(registry, since);
        } else {
            suspendedSince[registry] = 0;
            emit RegistryReactivated(registry);
        }
    }

    /// @notice A register of this factory, not suspended.
    function isActive(address registry) external view returns (bool) {
        return isRegistry[registry] && suspendedSince[registry] == 0;
    }

    function predictRegistryAddress(bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, salt);
    }

    function registryCount() external view returns (uint256) {
        return _registries.length;
    }

    /// @notice Registers in creation order, `count` from `start`.
    function registries(uint256 start, uint256 count) external view returns (address[] memory list) {
        uint256 total = _registries.length;
        if (start >= total) return new address[](0);
        uint256 end = start + count > total ? total : start + count;
        list = new address[](end - start);
        for (uint256 i = start; i < end; ++i) {
            list[i - start] = _registries[i];
        }
    }

    /// @notice Disabled: a factory without an owner could never create or suspend registers.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
