// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    LSP8IdentifiableDigitalAssetInitAbstract
} from "@lukso/lsp8-contracts/contracts/LSP8IdentifiableDigitalAssetInitAbstract.sol";
import {_LSP8_TOKENID_FORMAT_UNIQUE_ID} from "@lukso/lsp8-contracts/contracts/LSP8Constants.sol";
import {_LSP4_TOKEN_TYPE_NFT} from "@lukso/lsp4-contracts/contracts/LSP4Constants.sol";
import {
    EIP712Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    IServiceRegistryFactory,
    IVehicleRegistry,
    IERC725YReader
} from "./Interfaces.sol";

/// @title ServiceRegistry
/// @notice One business's register of professional records (docs/DESIGN.md §4.4, §6.3): one LSP8 token
/// per record (a service, an inspection, a repair), held by the business and not transferable — its
/// professional receipt. The history follows the car through the opaque `vehicleId`, not the token.
///
/// - The contract never sees a VIN, a plate, a mileage or a category: a record carries the `vehicleId`
///   (computed off-chain by ChainIntegrate's service), a commitment `keccak256(km, salt)`, the fingerprint
///   of the encrypted content and a reference to it on IPFS.
/// - Every write is an EIP-712 signature, so the relayer pays the gas: owner or operator (staff phones,
///   the business's software) for records; an **administrator** key of the owner's account for owner
///   operations (operators, data, ownership) — not any SIGN key (GasTrace review A01).
/// - Signatures have a maximum validity checked here, and a signer can cancel an unsent one (GasTrace
///   review G-07).
///
/// Deployed as EIP-1167 clones by `ServiceRegistryFactory`; not upgradeable.
contract ServiceRegistry is LSP8IdentifiableDigitalAssetInitAbstract, EIP712Upgradeable {
    // ---------------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------------

    /// @notice Longest a signature may be valid when it is used (deadline at most this far ahead).
    uint256 public constant MAX_SIGNATURE_VALIDITY = 7 days;
    /// @notice How far in the future a service date may be (clocks, time zones).
    uint256 public constant FUTURE_DATE_TOLERANCE = 1 days;

    /// @notice Per-record data key of the reference to the encrypted content on IPFS.
    bytes32 public constant RECORD_CONTENT_KEY = keccak256("MCBRecordContent");
    /// @notice Per-record data key of the record key wrapped for the vehicle's current holder (§5.3).
    bytes32 public constant RECORD_KEY_WRAP_KEY = keccak256("MCBRecordKeyWrap");

    /// @dev LSP6: `AddressPermissions:Permissions:<address>` prefix, and the administrator bits
    /// (ADDCONTROLLER, EDITPERMISSIONS), as up-onboarding's administrator keys have them.
    bytes10 private constant _LSP6_PERMISSIONS_PREFIX = 0x4b80742de2bf82acb363;
    uint256 private constant _ADMIN_BITS = 0x02 | 0x04;

    bytes32 public constant RECORD_SERVICE_TYPEHASH =
        keccak256("RecordService(address signer,bytes32 payloadHash,uint256 nonce,uint256 deadline)");
    bytes32 public constant SHARE_RECORD_KEY_TYPEHASH =
        keccak256(
            "ShareRecordKey(address signer,bytes32 recordId,bytes32 wrapHash,uint256 nonce,uint256 deadline)"
        );
    bytes32 public constant ISSUE_VEHICLE_TYPEHASH =
        keccak256(
            "IssueVehicle(address signer,bytes32 vehicleId,bytes32 contentHash,bytes32 recordRefHash,uint256 nonce,uint256 deadline)"
        );
    bytes32 public constant CANCEL_NONCE_TYPEHASH =
        keccak256("CancelNonce(address signer,uint256 cancelled,uint256 nonce,uint256 deadline)");
    bytes32 public constant SET_OPERATOR_TYPEHASH =
        keccak256("SetOperator(address operator,bool enabled,uint256 nonce,uint256 deadline)");
    bytes32 public constant SET_DATA_TYPEHASH =
        keccak256("SetData(bytes32[] dataKeys,bytes32 dataValuesHash,uint256 nonce,uint256 deadline)");
    bytes32 public constant TRANSFER_OWNERSHIP_TYPEHASH =
        keccak256("TransferOwnership(address newOwner,uint256 nonce,uint256 deadline)");
    bytes32 public constant ACCEPT_OWNERSHIP_TYPEHASH =
        keccak256("AcceptOwnership(address newOwner,uint256 nonce,uint256 deadline)");

    // ---------------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------------

    /// @notice What a record says. `corrects` is an earlier record of this register it replaces, or zero.
    struct RecordPayload {
        bytes32 recordId;
        bytes32 vehicleId;
        uint64 serviceDate;
        bytes32 kmCommitment;
        bytes32 contentHash;
        bytes contentRef;
        bytes32 corrects;
    }

    struct Record {
        bytes32 vehicleId;
        uint64 serviceDate;
        uint64 recordedAt;
        address signer;
        bytes32 kmCommitment;
        bytes32 contentHash;
        bytes32 corrects;
    }

    // ---------------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------------

    /// @notice The factory that created this register.
    address public factory;
    /// @notice The role written by the factory at creation (`ServiceRoles`).
    uint8 public role;
    /// @notice The account that may accept ownership (two-step transfer), or zero.
    address public pendingOwner;
    /// @notice Number of operators currently authorized.
    uint256 public operatorCount;

    mapping(address => bool) private _registryOperators;
    /// @dev signer => word index => bitmap of used or cancelled nonces (unordered nonces).
    mapping(address => mapping(uint256 => uint256)) private _nonceBitmap;
    mapping(bytes32 => Record) private _records;
    /// @dev Set only while `syncHolders` moves tokens.
    bool private _syncing;

    // ---------------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------------

    event ServiceRecorded(
        bytes32 indexed recordId,
        bytes32 indexed vehicleId,
        address indexed signer,
        uint64 serviceDate,
        bytes32 kmCommitment,
        bytes32 contentHash,
        bytes32 corrects,
        bytes contentRef
    );
    event RecordKeyShared(bytes32 indexed recordId, address indexed signer, bytes wrap);
    event VehicleIssued(bytes32 indexed vehicleId, bytes32 indexed vehicleTokenId, address indexed signer);
    event NonceCancelled(address indexed signer, uint256 nonce);
    event OperatorChanged(address indexed operator, bool enabled);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    error SignatureExpired(uint256 deadline);
    error SignatureValidityTooLong(uint256 deadline);
    error NonceAlreadyUsed(address signer, uint256 nonce);
    error InvalidSignature(address signer);
    error NotAuthorized(address signer);
    error NotAdministrator(address signer);
    error InvalidRecord();
    error RecordAlreadyExists(bytes32 recordId);
    error UnknownRecord(bytes32 recordId);
    error ServiceDateInFuture(uint64 serviceDate);
    error InvalidOperator(address operator);
    error OperatorUnchanged(address operator, bool enabled);
    error NotPendingOwner(address account);
    error TransfersDisabled();
    error RenounceDisabled();
    error NoVehicleRegistry();

    // ---------------------------------------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------------------------------------

    constructor() {
        _disableInitializers();
    }

    /// @notice Called once by the factory on a fresh clone.
    function initialize(string memory name_, string memory symbol_, address owner_, uint8 role_) external initializer {
        LSP8IdentifiableDigitalAssetInitAbstract._initialize(
            name_,
            symbol_,
            owner_,
            _LSP4_TOKEN_TYPE_NFT,
            _LSP8_TOKENID_FORMAT_UNIQUE_ID
        );
        __EIP712_init("MyCarBookServiceRegistry", "1");
        factory = msg.sender;
        role = role_;
    }

    // ---------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------

    function isOperator(address account) public view returns (bool) {
        return _registryOperators[account];
    }

    /// @notice True for the owner and for authorized operators: who may record services.
    function isAuthorized(address account) public view returns (bool) {
        return account == owner() || _registryOperators[account];
    }

    function isNonceUsed(address signer, uint256 nonce) public view returns (bool) {
        return _nonceBitmap[signer][nonce >> 8] & (1 << (nonce & 0xff)) != 0;
    }

    function recordOf(bytes32 recordId) external view returns (Record memory) {
        return _records[recordId];
    }

    /// @notice The EIP-712 domain separator (name "MyCarBookServiceRegistry", version "1").
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashPayload(RecordPayload calldata payload) public pure returns (bytes32) {
        return keccak256(abi.encode(payload));
    }

    /// @notice True when the factory has not suspended this register (readers show records made while
    /// suspended as such; the relayer does not serve a suspended register).
    function isActive() external view returns (bool) {
        return IServiceRegistryFactory(factory).isActive(address(this));
    }

    // ---------------------------------------------------------------------------------------------------
    // Records (owner or operator)
    // ---------------------------------------------------------------------------------------------------

    /// @notice Records a service: mints the record token to the owner and stores what the chain may know.
    function recordService(
        RecordPayload calldata payload,
        address signer,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes32 structHash = keccak256(
            abi.encode(RECORD_SERVICE_TYPEHASH, signer, hashPayload(payload), nonce, deadline)
        );
        _useSignature(signer, structHash, nonce, deadline, signature);
        if (!isAuthorized(signer)) revert NotAuthorized(signer);

        if (
            payload.recordId == bytes32(0) ||
            payload.vehicleId == bytes32(0) ||
            payload.kmCommitment == bytes32(0) ||
            payload.contentHash == bytes32(0) ||
            payload.contentRef.length == 0 ||
            payload.serviceDate == 0
        ) revert InvalidRecord();
        if (payload.serviceDate > block.timestamp + FUTURE_DATE_TOLERANCE) {
            revert ServiceDateInFuture(payload.serviceDate);
        }
        if (_exists(payload.recordId)) revert RecordAlreadyExists(payload.recordId);
        if (payload.corrects != bytes32(0) && !_exists(payload.corrects)) revert UnknownRecord(payload.corrects);

        _records[payload.recordId] = Record({
            vehicleId: payload.vehicleId,
            serviceDate: payload.serviceDate,
            recordedAt: uint64(block.timestamp),
            signer: signer,
            kmCommitment: payload.kmCommitment,
            contentHash: payload.contentHash,
            corrects: payload.corrects
        });
        _mint(owner(), payload.recordId, true, "");
        _setDataForTokenId(payload.recordId, RECORD_CONTENT_KEY, payload.contentRef);

        emit ServiceRecorded(
            payload.recordId,
            payload.vehicleId,
            signer,
            payload.serviceDate,
            payload.kmCommitment,
            payload.contentHash,
            payload.corrects,
            payload.contentRef
        );
    }

    /// @notice Hands a record's key to the vehicle's holder: the key wrapped for their vehicle key (§5.3).
    /// A later wrap (a new holder) replaces the earlier one; each stays in the events.
    function shareRecordKey(
        bytes32 recordId,
        bytes calldata wrap,
        address signer,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes32 structHash = keccak256(
            abi.encode(SHARE_RECORD_KEY_TYPEHASH, signer, recordId, keccak256(wrap), nonce, deadline)
        );
        _useSignature(signer, structHash, nonce, deadline, signature);
        if (!isAuthorized(signer)) revert NotAuthorized(signer);
        if (!_exists(recordId)) revert UnknownRecord(recordId);
        if (wrap.length == 0) revert InvalidRecord();
        _setDataForTokenId(recordId, RECORD_KEY_WRAP_KEY, wrap);
        emit RecordKeyShared(recordId, signer, wrap);
    }

    /// @notice A dealer or manufacturer issues a verified vehicle token to this register's owner (§4.2).
    /// The vehicle registry checks the role and that this register is active.
    function issueVehicle(
        bytes32 vehicleId,
        bytes32 contentHash,
        bytes calldata recordRef,
        address signer,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes32 vehicleTokenId) {
        bytes32 structHash = keccak256(
            abi.encode(
                ISSUE_VEHICLE_TYPEHASH,
                signer,
                vehicleId,
                contentHash,
                keccak256(recordRef),
                nonce,
                deadline
            )
        );
        _useSignature(signer, structHash, nonce, deadline, signature);
        if (!isAuthorized(signer)) revert NotAuthorized(signer);
        address vehicles = IServiceRegistryFactory(factory).vehicleRegistry();
        if (vehicles == address(0)) revert NoVehicleRegistry();
        vehicleTokenId = IVehicleRegistry(vehicles).issueVerified(vehicleId, contentHash, recordRef);
        emit VehicleIssued(vehicleId, vehicleTokenId, signer);
    }

    /// @notice Cancels an unsent signature of the caller (an operator with LYX, or the owner).
    function cancelNonce(uint256 nonce) external {
        _useNonce(msg.sender, nonce);
        emit NonceCancelled(msg.sender, nonce);
    }

    /// @notice Cancels an unsent signature, signed by its signer (no LYX needed).
    function cancelNonceSigned(
        uint256 cancelled,
        address signer,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes32 structHash = keccak256(abi.encode(CANCEL_NONCE_TYPEHASH, signer, cancelled, nonce, deadline));
        _useSignature(signer, structHash, nonce, deadline, signature);
        _useNonce(signer, cancelled);
        emit NonceCancelled(signer, cancelled);
    }

    // ---------------------------------------------------------------------------------------------------
    // Owner operations, signed by an administrator key of the owner's account
    // ---------------------------------------------------------------------------------------------------

    function setOperatorSigned(
        address operator,
        bool enabled,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes32 structHash = keccak256(abi.encode(SET_OPERATOR_TYPEHASH, operator, enabled, nonce, deadline));
        _useAdminSignature(owner(), structHash, nonce, deadline, signature);
        _setOperator(operator, enabled);
    }

    /// @notice Writes ERC725Y data of the register (data-key wraps, LSP4 metadata). The LSP4 name, symbol and
    /// token type and the LSP8 token ID format stay read-only, as in LSP8.
    function setDataSigned(
        bytes32[] calldata dataKeys,
        bytes[] calldata dataValues,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes32 structHash = keccak256(
            abi.encode(
                SET_DATA_TYPEHASH,
                keccak256(abi.encodePacked(dataKeys)),
                keccak256(abi.encode(dataValues)),
                nonce,
                deadline
            )
        );
        _useAdminSignature(owner(), structHash, nonce, deadline, signature);
        if (dataKeys.length == 0 || dataKeys.length != dataValues.length) revert InvalidRecord();
        for (uint256 i; i < dataKeys.length; ++i) {
            _setData(dataKeys[i], dataValues[i]);
        }
    }

    function transferOwnershipSigned(
        address newOwner,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes32 structHash = keccak256(abi.encode(TRANSFER_OWNERSHIP_TYPEHASH, newOwner, nonce, deadline));
        _useAdminSignature(owner(), structHash, nonce, deadline, signature);
        _startOwnershipTransfer(newOwner);
    }

    function acceptOwnershipSigned(uint256 nonce, uint256 deadline, bytes calldata signature) external {
        address newOwner = pendingOwner;
        if (newOwner == address(0)) revert NotPendingOwner(address(0));
        bytes32 structHash = keccak256(abi.encode(ACCEPT_OWNERSHIP_TYPEHASH, newOwner, nonce, deadline));
        _useAdminSignature(newOwner, structHash, nonce, deadline, signature);
        _acceptOwnership(newOwner);
    }

    // ---------------------------------------------------------------------------------------------------
    // Owner operations, direct (an owner paying its own gas; for a Universal Profile its Key Manager
    // checks the calling key's permissions)
    // ---------------------------------------------------------------------------------------------------

    function setOperator(address operator, bool enabled) external onlyOwner {
        _setOperator(operator, enabled);
    }

    /// @notice Two-step: sets `pendingOwner`, which must accept.
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _startOwnershipTransfer(newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotPendingOwner(msg.sender);
        _acceptOwnership(msg.sender);
    }

    /// @notice Disabled: a register without an owner could never be administered again.
    function renounceOwnership() public virtual override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------------------------------------------
    // Tokens
    // ---------------------------------------------------------------------------------------------------

    /// @notice Moves the given records to the current owner after an ownership change. Anyone may call it:
    /// it can only move records to the owner.
    function syncHolders(bytes32[] calldata tokenIds) external {
        address holder = owner();
        _syncing = true;
        for (uint256 i; i < tokenIds.length; ++i) {
            address current = tokenOwnerOf(tokenIds[i]);
            if (current != holder) {
                _transfer(current, holder, tokenIds[i], true, "");
            }
        }
        _syncing = false;
    }

    /// @dev Records are the business's receipts: only minting and `syncHolders` move them.
    function _beforeTokenTransfer(
        address from,
        address to,
        bytes32 tokenId,
        bool force,
        bytes memory data
    ) internal virtual override {
        if (from != address(0) && (!_syncing || to != owner())) revert TransfersDisabled();
        super._beforeTokenTransfer(from, to, tokenId, force, data);
    }

    // ---------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        if (deadline > block.timestamp + MAX_SIGNATURE_VALIDITY) revert SignatureValidityTooLong(deadline);
    }

    function _useNonce(address signer, uint256 nonce) internal {
        uint256 word = nonce >> 8;
        uint256 bit = 1 << (nonce & 0xff);
        if (_nonceBitmap[signer][word] & bit != 0) revert NonceAlreadyUsed(signer, nonce);
        _nonceBitmap[signer][word] |= bit;
    }

    /// @dev A signature of `signer` (an EOA key, or an account through ERC-1271).
    function _useSignature(
        address signer,
        bytes32 structHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        _checkDeadline(deadline);
        _useNonce(signer, nonce);
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) revert InvalidSignature(signer);
    }

    /// @dev A signature of `account` made by one of its **administrator** keys (GasTrace review A01): for
    /// an EOA the account itself; for a Universal Profile, a controller key that the account accepts
    /// (ERC-1271) and that has ADDCONTROLLER and EDITPERMISSIONS in its LSP6 permissions.
    function _useAdminSignature(
        address account,
        bytes32 structHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        _checkDeadline(deadline);
        _useNonce(account, nonce);
        bytes32 digest = _hashTypedDataV4(structHash);
        if (account.code.length == 0) {
            if (!SignatureChecker.isValidSignatureNow(account, digest, signature)) revert InvalidSignature(account);
            return;
        }
        (address key, ECDSA.RecoverError err) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) revert InvalidSignature(account);
        if (!SignatureChecker.isValidERC1271SignatureNow(account, digest, signature)) {
            revert InvalidSignature(account);
        }
        bytes32 permissionsKey = bytes32(abi.encodePacked(_LSP6_PERMISSIONS_PREFIX, bytes2(0), key));
        uint256 permissions;
        try IERC725YReader(account).getData(permissionsKey) returns (bytes memory value) {
            if (value.length == 32) permissions = uint256(bytes32(value));
        } catch {
            permissions = 0;
        }
        if (permissions & _ADMIN_BITS != _ADMIN_BITS) revert NotAdministrator(key);
    }

    function _setOperator(address operator, bool enabled) internal {
        if (operator == address(0) || operator == address(this)) revert InvalidOperator(operator);
        if (_registryOperators[operator] == enabled) revert OperatorUnchanged(operator, enabled);
        _registryOperators[operator] = enabled;
        if (enabled) {
            ++operatorCount;
        } else {
            --operatorCount;
        }
        emit OperatorChanged(operator, enabled);
    }

    function _startOwnershipTransfer(address newOwner) internal {
        if (newOwner == address(0) || newOwner == owner()) revert NotPendingOwner(newOwner);
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    function _acceptOwnership(address newOwner) internal {
        pendingOwner = address(0);
        _transferOwnership(newOwner);
    }
}
