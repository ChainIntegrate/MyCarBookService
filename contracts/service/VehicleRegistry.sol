// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LSP8IdentifiableDigitalAsset} from "@lukso/lsp8-contracts/contracts/LSP8IdentifiableDigitalAsset.sol";
import {_LSP8_TOKENID_FORMAT_NUMBER} from "@lukso/lsp8-contracts/contracts/LSP8Constants.sol";
import {_LSP4_TOKEN_TYPE_NFT} from "@lukso/lsp4-contracts/contracts/LSP4Constants.sol";
import {IServiceRegistryFactory, IOwnedRegistry} from "./Interfaces.sol";
import {ServiceRoles} from "./ServiceRoles.sol";

/// @title VehicleRegistry
/// @notice One LSP8 token per vehicle, held by its current owner (docs/DESIGN.md §4.2, §6.1).
///
/// - Open: anyone may mint a vehicle for themselves (the platform's value is elsewhere, §3.1). A
///   **verified** token is issued by a business register of the factory with a dealer or manufacturer
///   role, minted to that register's owner.
/// - Precedence without loops: private tokens of a `vehicleId` read as "superseded" as soon as the
///   `vehicleId` has a verified token, so nobody can block a verified issuance by minting many private
///   tokens. A second verified token is minted "in conflict". The **arbiter** (a ChainIntegrate key with
///   that power only) can override a token's status and choose the verified token of a `vehicleId`.
/// - No VIN, plate or personal data: the token holds the `vehicleId` (computed off-chain by
///   ChainIntegrate's service), the fingerprint of the encrypted vehicle record and a reference to it.
/// - Transfers in two steps (offer, accept): no vehicle is pushed into someone's account.
/// - The contract owner cannot change any vehicle's data (V2 audit MCB-04).
contract VehicleRegistry is LSP8IdentifiableDigitalAsset {
    enum Status {
        None,
        Active,
        Superseded,
        Conflict
    }

    struct Vehicle {
        bytes32 vehicleId;
        address issuer;
        uint8 issuerRole;
        uint64 mintedAt;
    }

    /// @notice Per-token data key of the reference to the encrypted vehicle record on IPFS.
    bytes32 public constant VEHICLE_RECORD_KEY = keccak256("MCBVehicleRecord");

    IServiceRegistryFactory public immutable factory;
    /// @notice The key that may decide disputes (token status only). Set by the owner, replaceable.
    address public arbiter;

    uint256 private _nextTokenId = 1;
    mapping(bytes32 => Vehicle) private _vehicles;
    /// @notice The verified token of a `vehicleId`, or zero.
    mapping(bytes32 => bytes32) public verifiedTokenOf;
    mapping(bytes32 => bool) private _conflict;
    /// @dev Arbiter's decision on a token (`Status.None` when there is none).
    mapping(bytes32 => Status) private _override;
    /// @notice The account a token is offered to (two-step transfer), or zero.
    mapping(bytes32 => address) public pendingTransferOf;
    bool private _accepting;

    event VehicleMinted(
        bytes32 indexed tokenId,
        bytes32 indexed vehicleId,
        address indexed issuer,
        uint8 issuerRole,
        bool conflict,
        bytes32 contentHash,
        bytes recordRef
    );
    event VehicleRecordUpdated(bytes32 indexed tokenId, bytes32 indexed vehicleId, bytes32 contentHash, bytes recordRef);
    event EntryLogged(
        bytes32 indexed tokenId,
        bytes32 indexed vehicleId,
        address indexed holder,
        bytes32 kmCommitment,
        bytes32 contentHash,
        bytes entryRef
    );
    event TransferOffered(bytes32 indexed tokenId, address indexed from, address indexed to);
    event TransferOfferCancelled(bytes32 indexed tokenId, address indexed from);
    event ArbiterChanged(address indexed previousArbiter, address indexed newArbiter);
    event StatusArbitrated(bytes32 indexed tokenId, Status status, bytes32 reasonRef);
    event VerifiedTokenSet(bytes32 indexed vehicleId, bytes32 indexed tokenId, bytes32 reasonRef);

    error InvalidVehicle();
    error VehicleAlreadyVerified(bytes32 vehicleId);
    error NotAnActiveIssuer(address caller);
    error RoleCannotIssue(uint8 role);
    error NotHolder(address caller);
    error UnknownVehicle(bytes32 tokenId);
    error InvalidRecipient(address to);
    error NoPendingTransfer(bytes32 tokenId);
    error NotOfferedTo(address caller);
    error TransfersOnlyByOffer();
    error NotArbiter(address caller);
    error InvalidStatus();
    error NotVerifiedToken(bytes32 tokenId);
    error OwnerCannotEditVehicles();
    error RenounceDisabled();

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_,
        address factory_
    ) LSP8IdentifiableDigitalAsset(name_, symbol_, owner_, _LSP4_TOKEN_TYPE_NFT, _LSP8_TOKENID_FORMAT_NUMBER) {
        if (factory_ == address(0)) revert InvalidVehicle();
        factory = IServiceRegistryFactory(factory_);
    }

    // ---------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------

    function vehicleOf(bytes32 tokenId) external view returns (Vehicle memory) {
        return _vehicles[tokenId];
    }

    /// @notice A token's status: the arbiter's decision if any; otherwise a private token is superseded
    /// when its `vehicleId` has a verified token, a second verified token is in conflict.
    function statusOf(bytes32 tokenId) public view returns (Status) {
        Vehicle storage v = _vehicles[tokenId];
        if (v.vehicleId == bytes32(0)) return Status.None;
        Status decided = _override[tokenId];
        if (decided != Status.None) return decided;
        if (v.issuerRole == 0) {
            return verifiedTokenOf[v.vehicleId] != bytes32(0) ? Status.Superseded : Status.Active;
        }
        return _conflict[tokenId] ? Status.Conflict : Status.Active;
    }

    // ---------------------------------------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------------------------------------

    /// @notice Anyone mints a vehicle for themselves. Refused when the `vehicleId` already has a verified
    /// token (the owner receives that one instead, by transfer).
    function mint(bytes32 vehicleId, bytes32 contentHash, bytes calldata recordRef) external returns (bytes32 tokenId) {
        if (vehicleId == bytes32(0) || contentHash == bytes32(0) || recordRef.length == 0) revert InvalidVehicle();
        if (verifiedTokenOf[vehicleId] != bytes32(0)) revert VehicleAlreadyVerified(vehicleId);
        tokenId = _mintVehicle(msg.sender, vehicleId, msg.sender, 0, false, contentHash, recordRef);
    }

    /// @notice Called by an active business register with a dealer or manufacturer role: mints a
    /// verified token to the register's owner. A second verified token on the same `vehicleId` is minted
    /// in conflict.
    function issueVerified(
        bytes32 vehicleId,
        bytes32 contentHash,
        bytes calldata recordRef
    ) external returns (bytes32 tokenId) {
        if (!factory.isActive(msg.sender)) revert NotAnActiveIssuer(msg.sender);
        uint8 role = factory.roleOf(msg.sender);
        if (!ServiceRoles.canIssueVehicles(role)) revert RoleCannotIssue(role);
        if (vehicleId == bytes32(0) || contentHash == bytes32(0) || recordRef.length == 0) revert InvalidVehicle();
        bool conflict = verifiedTokenOf[vehicleId] != bytes32(0);
        address holder = IOwnedRegistry(msg.sender).owner();
        tokenId = _mintVehicle(holder, vehicleId, msg.sender, role, conflict, contentHash, recordRef);
        if (conflict) {
            _conflict[tokenId] = true;
        } else {
            verifiedTokenOf[vehicleId] = tokenId;
        }
    }

    // ---------------------------------------------------------------------------------------------------
    // Holder operations
    // ---------------------------------------------------------------------------------------------------

    /// @notice A new version of the (encrypted) vehicle record; earlier versions stay in the events.
    function updateRecord(bytes32 tokenId, bytes32 contentHash, bytes calldata recordRef) external {
        _onlyHolder(tokenId);
        if (contentHash == bytes32(0) || recordRef.length == 0) revert InvalidVehicle();
        _setDataForTokenId(tokenId, VEHICLE_RECORD_KEY, recordRef);
        emit VehicleRecordUpdated(tokenId, _vehicles[tokenId].vehicleId, contentHash, recordRef);
    }

    /// @notice An entry of the owner's personal logbook: encrypted content, mileage commitment.
    function logEntry(bytes32 tokenId, bytes32 kmCommitment, bytes32 contentHash, bytes calldata entryRef) external {
        _onlyHolder(tokenId);
        if (kmCommitment == bytes32(0) || contentHash == bytes32(0) || entryRef.length == 0) revert InvalidVehicle();
        emit EntryLogged(tokenId, _vehicles[tokenId].vehicleId, msg.sender, kmCommitment, contentHash, entryRef);
    }

    /// @notice Offers the vehicle to `to`, who must accept. A new offer replaces the previous one.
    function offerTransfer(bytes32 tokenId, address to) external {
        _onlyHolder(tokenId);
        if (to == address(0) || to == msg.sender || to == address(this)) revert InvalidRecipient(to);
        pendingTransferOf[tokenId] = to;
        emit TransferOffered(tokenId, msg.sender, to);
    }

    function cancelTransferOffer(bytes32 tokenId) external {
        _onlyHolder(tokenId);
        if (pendingTransferOf[tokenId] == address(0)) revert NoPendingTransfer(tokenId);
        delete pendingTransferOf[tokenId];
        emit TransferOfferCancelled(tokenId, msg.sender);
    }

    /// @notice The recipient of an offer accepts it and receives the vehicle.
    function acceptTransfer(bytes32 tokenId) external {
        address to = pendingTransferOf[tokenId];
        if (to == address(0)) revert NoPendingTransfer(tokenId);
        if (msg.sender != to) revert NotOfferedTo(msg.sender);
        delete pendingTransferOf[tokenId];
        _accepting = true;
        _transfer(tokenOwnerOf(tokenId), to, tokenId, true, "");
        _accepting = false;
    }

    // ---------------------------------------------------------------------------------------------------
    // Arbiter (ChainIntegrate, disputes only)
    // ---------------------------------------------------------------------------------------------------

    function setArbiter(address newArbiter) external onlyOwner {
        emit ArbiterChanged(arbiter, newArbiter);
        arbiter = newArbiter;
    }

    /// @notice Sets a token's status (`Active` or `Superseded`) after a check; `Status.None` removes the
    /// decision. `reasonRef` points to the decision's record (off-chain).
    function arbitrate(bytes32 tokenId, Status status, bytes32 reasonRef) external {
        _onlyArbiter();
        if (_vehicles[tokenId].vehicleId == bytes32(0)) revert UnknownVehicle(tokenId);
        if (status == Status.Conflict) revert InvalidStatus();
        _override[tokenId] = status;
        emit StatusArbitrated(tokenId, status, reasonRef);
    }

    /// @notice Resolves a conflict: `tokenId` (a verified token) becomes the verified token of its
    /// `vehicleId`. The other verified tokens are set with `arbitrate`.
    function setVerifiedToken(bytes32 tokenId, bytes32 reasonRef) external {
        _onlyArbiter();
        Vehicle storage v = _vehicles[tokenId];
        if (v.vehicleId == bytes32(0)) revert UnknownVehicle(tokenId);
        if (v.issuerRole == 0) revert NotVerifiedToken(tokenId);
        verifiedTokenOf[v.vehicleId] = tokenId;
        _conflict[tokenId] = false;
        emit VerifiedTokenSet(v.vehicleId, tokenId, reasonRef);
    }

    // ---------------------------------------------------------------------------------------------------
    // What the contract owner cannot do
    // ---------------------------------------------------------------------------------------------------

    function setDataForTokenId(bytes32, bytes32, bytes memory) public pure override {
        revert OwnerCannotEditVehicles();
    }

    function setDataBatchForTokenIds(bytes32[] memory, bytes32[] memory, bytes[] memory) public pure override {
        revert OwnerCannotEditVehicles();
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------

    function _mintVehicle(
        address to,
        bytes32 vehicleId,
        address issuer,
        uint8 issuerRole,
        bool conflict,
        bytes32 contentHash,
        bytes calldata recordRef
    ) internal returns (bytes32 tokenId) {
        tokenId = bytes32(_nextTokenId);
        ++_nextTokenId;
        _vehicles[tokenId] = Vehicle({
            vehicleId: vehicleId,
            issuer: issuer,
            issuerRole: issuerRole,
            mintedAt: uint64(block.timestamp)
        });
        _mint(to, tokenId, true, "");
        _setDataForTokenId(tokenId, VEHICLE_RECORD_KEY, recordRef);
        emit VehicleMinted(tokenId, vehicleId, issuer, issuerRole, conflict, contentHash, recordRef);
    }

    function _onlyHolder(bytes32 tokenId) internal view {
        if (!_exists(tokenId)) revert UnknownVehicle(tokenId);
        if (tokenOwnerOf(tokenId) != msg.sender) revert NotHolder(msg.sender);
    }

    function _onlyArbiter() internal view {
        if (msg.sender != arbiter || msg.sender == address(0)) revert NotArbiter(msg.sender);
    }

    /// @dev Only minting and `acceptTransfer` move vehicles (no direct `transfer`, no operator push).
    function _beforeTokenTransfer(
        address from,
        address to,
        bytes32 tokenId,
        bool force,
        bytes memory data
    ) internal virtual override {
        if (from != address(0) && !_accepting) revert TransfersOnlyByOffer();
        if (from != address(0)) delete pendingTransferOf[tokenId];
        super._beforeTokenTransfer(from, to, tokenId, force, data);
    }
}
