// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVaultIDRegistry {
    function isIssuerActive(address issuer) external view returns (bool);
    function canIssuerMint(address issuer) external view returns (bool);
    function hasActiveBasicSubscription(address subscriber) external view returns (bool);
    function consumeBasicMint(address subscriber) external;
    function issuerAdminRights(address issuer) external view returns (bool);
}

/**
 * @title VaultID
 * @notice Soulbound ERC-721 credential system with three-actor revocation,
 *         registry-mediated subscriptions, membership data, and recovery.
 */
contract VaultID is ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct VaultData {
        address issuer; // who minted this credential
        string credentialType; // type string
        uint256 expiry; // unix timestamp, 0 = no expiry
        address recoveryWallet; // optional recovery wallet
        string encryptedPayloadRef; // IPFS or encrypted URI for payload
        string metadataURI; // public metadata URI
        bool burned; // true if deleted/burned
    }

    struct RevocationStatus {
        bool revokedByOwner;
        bool revokedByIssuer;
        bool revokedByAdmin;
    }

    struct MembershipData {
        bool exists;
        uint256 membershipExpiry;
        string tier;
        bool active; // derived: only true if not revoked/expired/burned
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(uint256 => VaultData) private _vaults;
    mapping(uint256 => RevocationStatus) private _revocation;
    mapping(uint256 => MembershipData) private _membership;

    uint256 private _nextTokenId;

    address public feeRecipient;
    uint256 public ethMintPrice;
    uint256 public usdcMintPrice;

    address public immutable USDC_ADDRESS;
    address public immutable CLAWD_ADDRESS;

    // Registry linkage with 2-step delayed update
    address public registry;
    address public pendingRegistry;
    uint256 public registryUpdateTime;
    uint256 public constant REGISTRY_UPDATE_DELAY = 48 hours;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event VaultMinted(uint256 indexed tokenId, address indexed to, address indexed issuer, string credentialType);
    event VaultBurned(uint256 indexed tokenId);
    event VaultRecovered(uint256 indexed oldTokenId, uint256 indexed newTokenId, address indexed newOwner);
    event RecoveryWalletSet(uint256 indexed tokenId, address recoveryWallet);

    event Revoked(uint256 indexed tokenId, address indexed actor, uint8 indexed flag); // 0=owner,1=issuer,2=admin
    event Unrevoked(uint256 indexed tokenId, address indexed actor, uint8 indexed flag);

    event MembershipSet(uint256 indexed tokenId, uint256 membershipExpiry, string tier);
    event MembershipExpiryExtended(uint256 indexed tokenId, uint256 newExpiry);
    event ExpiryExtended(uint256 indexed tokenId, uint256 newExpiry);

    event FeeRecipientUpdated(address indexed newFeeRecipient);
    event ETHMintPriceUpdated(uint256 price);
    event USDCMintPriceUpdated(uint256 price);

    event RegistryUpdateProposed(address indexed newRegistry, uint256 applyAt);
    event RegistryUpdateCancelled(address indexed cancelled);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error Soulbound();
    error ApprovalsDisabled();
    error NotTokenOwner();
    error NotIssuer();
    error NotIssuerOrTokenOwner();
    error TokenNotExist();
    error TokenBurned();
    error TokenRevoked();
    error TokenExpired();
    error InvalidPayment();
    error InvalidAddress();
    error PaymentTransferFailed();
    error IssuerNotEligible();
    error NoSubscription();
    error CLAWDNotConfigured();
    error NoPendingProposal();
    error DelayNotElapsed();
    error InvalidExpiry();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        address _owner,
        address _feeRecipient,
        address _usdcAddress,
        address _clawdAddress,
        uint256 _ethMintPrice,
        uint256 _usdcMintPrice
    ) ERC721("VaultID", "VID") Ownable(_owner) {
        if (_feeRecipient == address(0)) revert InvalidAddress();
        if (_usdcAddress == address(0)) revert InvalidAddress();

        feeRecipient = _feeRecipient;
        USDC_ADDRESS = _usdcAddress;
        CLAWD_ADDRESS = _clawdAddress;
        ethMintPrice = _ethMintPrice;
        usdcMintPrice = _usdcMintPrice;
        _nextTokenId = 1;
    }

    // ---------------------------------------------------------------------
    // Soulbound enforcement
    // ---------------------------------------------------------------------

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        // Allow mint (from==0) and burn (to==0). Block all transfers.
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override {
        revert ApprovalsDisabled();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert ApprovalsDisabled();
    }

    // ---------------------------------------------------------------------
    // Internal mint helper
    // ---------------------------------------------------------------------

    function _mintVault(
        address to,
        address issuer,
        string memory credentialType,
        string memory encryptedPayloadRef,
        string memory metadataURI,
        uint256 expiry,
        address recoveryWallet
    ) internal returns (uint256 tokenId) {
        if (to == address(0)) revert InvalidAddress();
        if (expiry != 0 && expiry <= block.timestamp) revert InvalidExpiry();

        tokenId = _nextTokenId++;
        _vaults[tokenId] = VaultData({
            issuer: issuer,
            credentialType: credentialType,
            expiry: expiry,
            recoveryWallet: recoveryWallet,
            encryptedPayloadRef: encryptedPayloadRef,
            metadataURI: metadataURI,
            burned: false
        });
        _mint(to, tokenId);
        emit VaultMinted(tokenId, to, issuer, credentialType);
    }

    // ---------------------------------------------------------------------
    // Public minting
    // ---------------------------------------------------------------------

    /// @notice Mint a self-issued credential paying in ETH.
    function mintWithETH(
        string calldata credentialType,
        string calldata encryptedPayloadRef,
        string calldata metadataURI,
        uint256 expiry,
        address recoveryWallet
    ) external payable nonReentrant returns (uint256 tokenId) {
        if (msg.value != ethMintPrice) revert InvalidPayment();

        // Forward to fee recipient
        (bool ok, ) = payable(feeRecipient).call{ value: msg.value }("");
        if (!ok) revert PaymentTransferFailed();

        tokenId = _mintVault(
            msg.sender,
            msg.sender,
            credentialType,
            encryptedPayloadRef,
            metadataURI,
            expiry,
            recoveryWallet
        );
    }

    /// @notice Mint a self-issued credential paying in USDC.
    function mintWithUSDC(
        string calldata credentialType,
        string calldata encryptedPayloadRef,
        string calldata metadataURI,
        uint256 expiry,
        address recoveryWallet
    ) external nonReentrant returns (uint256 tokenId) {
        IERC20(USDC_ADDRESS).safeTransferFrom(msg.sender, feeRecipient, usdcMintPrice);
        tokenId = _mintVault(
            msg.sender,
            msg.sender,
            credentialType,
            encryptedPayloadRef,
            metadataURI,
            expiry,
            recoveryWallet
        );
    }

    /// @notice Mint a self-issued credential using a basic subscription via registry.
    function mintWithSubscription(
        string calldata credentialType,
        string calldata encryptedPayloadRef,
        string calldata metadataURI,
        uint256 expiry,
        address recoveryWallet
    ) external nonReentrant returns (uint256 tokenId) {
        if (registry == address(0)) revert NoSubscription();
        IVaultIDRegistry reg = IVaultIDRegistry(registry);
        if (!reg.hasActiveBasicSubscription(msg.sender)) revert NoSubscription();
        reg.consumeBasicMint(msg.sender);

        tokenId = _mintVault(
            msg.sender,
            msg.sender,
            credentialType,
            encryptedPayloadRef,
            metadataURI,
            expiry,
            recoveryWallet
        );
    }

    /// @notice Mint a credential AS an issuer on behalf of `to`.
    function issuerMint(
        address to,
        string calldata credentialType,
        string calldata encryptedPayloadRef,
        string calldata metadataURI,
        uint256 expiry,
        address recoveryWallet
    ) external nonReentrant returns (uint256 tokenId) {
        if (registry == address(0)) revert IssuerNotEligible();
        if (!IVaultIDRegistry(registry).canIssuerMint(msg.sender)) revert IssuerNotEligible();

        tokenId = _mintVault(
            to,
            msg.sender,
            credentialType,
            encryptedPayloadRef,
            metadataURI,
            expiry,
            recoveryWallet
        );
    }

    // ---------------------------------------------------------------------
    // Revocation — three flags, each clearable only by the same actor
    // ---------------------------------------------------------------------

    function revoke(uint256 tokenId) external {
        _requireExists(tokenId);
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        _revocation[tokenId].revokedByOwner = true;
        emit Revoked(tokenId, msg.sender, 0);
    }

    function revokeByIssuer(uint256 tokenId) external {
        _requireExists(tokenId);
        VaultData storage v = _vaults[tokenId];
        if (msg.sender != v.issuer) revert NotIssuer();
        // Must still hold administrative rights (active profile, lapsed sub OK).
        if (registry != address(0) && !IVaultIDRegistry(registry).issuerAdminRights(msg.sender)) {
            revert IssuerNotEligible();
        }
        _revocation[tokenId].revokedByIssuer = true;
        emit Revoked(tokenId, msg.sender, 1);
    }

    function revokeByAdmin(uint256 tokenId) external onlyOwner {
        _requireExists(tokenId);
        _revocation[tokenId].revokedByAdmin = true;
        emit Revoked(tokenId, msg.sender, 2);
    }

    function unrevoke(uint256 tokenId) external {
        _requireExists(tokenId);
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        _revocation[tokenId].revokedByOwner = false;
        emit Unrevoked(tokenId, msg.sender, 0);
    }

    function unrevokeByIssuer(uint256 tokenId) external {
        _requireExists(tokenId);
        VaultData storage v = _vaults[tokenId];
        if (msg.sender != v.issuer) revert NotIssuer();
        if (registry != address(0) && !IVaultIDRegistry(registry).issuerAdminRights(msg.sender)) {
            revert IssuerNotEligible();
        }
        _revocation[tokenId].revokedByIssuer = false;
        emit Unrevoked(tokenId, msg.sender, 1);
    }

    function unrevokeByAdmin(uint256 tokenId) external onlyOwner {
        _requireExists(tokenId);
        _revocation[tokenId].revokedByAdmin = false;
        emit Unrevoked(tokenId, msg.sender, 2);
    }

    function revocationStatus(uint256 tokenId)
        external
        view
        returns (bool byOwner, bool byIssuer, bool byAdmin)
    {
        RevocationStatus storage r = _revocation[tokenId];
        return (r.revokedByOwner, r.revokedByIssuer, r.revokedByAdmin);
    }

    function isRevoked(uint256 tokenId) public view returns (bool) {
        RevocationStatus storage r = _revocation[tokenId];
        return r.revokedByOwner || r.revokedByIssuer || r.revokedByAdmin;
    }

    function isValid(uint256 tokenId) public view returns (bool) {
        VaultData storage v = _vaults[tokenId];
        if (v.burned) return false;
        if (_ownerOf(tokenId) == address(0)) return false;
        if (isRevoked(tokenId)) return false;
        if (v.expiry != 0 && v.expiry <= block.timestamp) return false;
        return true;
    }

    // ---------------------------------------------------------------------
    // Recovery
    // ---------------------------------------------------------------------

    /**
     * @notice Update the recovery wallet for a token.
     * @dev Blocks if burned or any revocation flag is active.
     */
    function setRecoveryWallet(uint256 tokenId, address newRecovery) external {
        _requireExists(tokenId);
        VaultData storage v = _vaults[tokenId];
        if (v.burned) revert TokenBurned();
        if (isRevoked(tokenId)) revert TokenRevoked();
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        v.recoveryWallet = newRecovery;
        emit RecoveryWalletSet(tokenId, newRecovery);
    }

    /**
     * @notice Recover a credential to a new owner.
     * @dev Burns the old token and mints a new one with the same VaultData.
     *      Revocation flags are preserved (NOT reset).
     *      Caller must be the recoveryWallet of the token.
     */
    function recoverVault(uint256 tokenId, address newOwner) external nonReentrant returns (uint256 newTokenId) {
        _requireExists(tokenId);
        VaultData storage v = _vaults[tokenId];
        if (v.burned) revert TokenBurned();
        if (isRevoked(tokenId)) revert TokenRevoked();
        if (newOwner == address(0)) revert InvalidAddress();
        if (msg.sender != v.recoveryWallet) revert NotTokenOwner();

        // Snapshot the data we need to preserve before burning.
        address issuer = v.issuer;
        string memory credentialType = v.credentialType;
        uint256 expiry = v.expiry;
        string memory encryptedPayloadRef = v.encryptedPayloadRef;
        string memory metadataURI = v.metadataURI;
        // Preserve revocation flags on the OLD record explicitly: the new token gets fresh
        // (cleared) flags ONLY because we already required none are set above. The spec says
        // "Must NOT reset revocation flags" - i.e. we cannot use recovery to wipe a revoke.
        // Since we already block if any flag is active, this invariant holds.

        // Burn old token
        v.burned = true;
        _burn(tokenId);
        emit VaultBurned(tokenId);

        // Mint new token preserving data
        newTokenId = _nextTokenId++;
        _vaults[newTokenId] = VaultData({
            issuer: issuer,
            credentialType: credentialType,
            expiry: expiry,
            recoveryWallet: address(0), // new owner can set a new recovery wallet if desired
            encryptedPayloadRef: encryptedPayloadRef,
            metadataURI: metadataURI,
            burned: false
        });
        _mint(newOwner, newTokenId);
        emit VaultMinted(newTokenId, newOwner, issuer, credentialType);
        emit VaultRecovered(tokenId, newTokenId, newOwner);
    }

    // ---------------------------------------------------------------------
    // Burn
    // ---------------------------------------------------------------------

    function burn(uint256 tokenId) external {
        _requireExists(tokenId);
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        _vaults[tokenId].burned = true;
        _burn(tokenId);
        emit VaultBurned(tokenId);
    }

    // ---------------------------------------------------------------------
    // Membership
    // ---------------------------------------------------------------------

    function setMembershipData(
        uint256 tokenId,
        uint256 membershipExpiry,
        string calldata tier
    ) external {
        _requireExists(tokenId);
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        MembershipData storage m = _membership[tokenId];
        m.exists = true;
        m.membershipExpiry = membershipExpiry;
        m.tier = tier;
        // active is derived in the getter; we never persist a true value here.
        m.active = false;
        emit MembershipSet(tokenId, membershipExpiry, tier);
    }

    /**
     * @notice Extend the credential expiry. Token owner OR issuer (with admin rights) may call.
     * @dev MUST NOT mark membership.active = true when any revocation flag is active.
     */
    function extendExpiry(uint256 tokenId, uint256 newExpiry) external {
        _requireExists(tokenId);
        VaultData storage v = _vaults[tokenId];
        if (v.burned) revert TokenBurned();

        bool isOwner = ownerOf(tokenId) == msg.sender;
        bool isIssuer = msg.sender == v.issuer;
        if (!isOwner && !isIssuer) revert NotIssuerOrTokenOwner();
        if (isIssuer && !isOwner) {
            if (registry == address(0)) revert IssuerNotEligible();
            if (!IVaultIDRegistry(registry).issuerAdminRights(msg.sender)) revert IssuerNotEligible();
        }
        if (newExpiry != 0 && newExpiry <= block.timestamp) revert InvalidExpiry();

        v.expiry = newExpiry;
        emit ExpiryExtended(tokenId, newExpiry);

        MembershipData storage m = _membership[tokenId];
        if (m.exists) {
            m.membershipExpiry = newExpiry;
            // Crucially, never set m.active = true here. The getter computes active dynamically.
            m.active = false;
            emit MembershipExpiryExtended(tokenId, newExpiry);
        }
    }

    function getMembershipData(uint256 tokenId) external view returns (MembershipData memory) {
        MembershipData memory m = _membership[tokenId];
        VaultData storage v = _vaults[tokenId];
        bool active = m.exists
            && m.membershipExpiry > block.timestamp
            && !isRevoked(tokenId)
            && !v.burned
            && _ownerOf(tokenId) != address(0);
        m.active = active;
        return m;
    }

    // ---------------------------------------------------------------------
    // VaultData getter
    // ---------------------------------------------------------------------

    function getVaultData(uint256 tokenId) external view returns (VaultData memory) {
        return _vaults[tokenId];
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _vaults[tokenId].metadataURI;
    }

    // ---------------------------------------------------------------------
    // Registry update (2-step with delay, bypassed only for initial setup)
    // ---------------------------------------------------------------------

    function proposeRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert InvalidAddress();
        pendingRegistry = newRegistry;
        // If registry is unset, allow immediate apply (initial linkage).
        registryUpdateTime = registry == address(0) ? block.timestamp : block.timestamp + REGISTRY_UPDATE_DELAY;
        emit RegistryUpdateProposed(newRegistry, registryUpdateTime);
    }

    function cancelRegistryProposal() external onlyOwner {
        address cancelled = pendingRegistry;
        if (cancelled == address(0)) revert NoPendingProposal();
        pendingRegistry = address(0);
        registryUpdateTime = 0;
        emit RegistryUpdateCancelled(cancelled);
    }

    function applyRegistryProposal() external onlyOwner {
        if (pendingRegistry == address(0)) revert NoPendingProposal();
        if (block.timestamp < registryUpdateTime) revert DelayNotElapsed();
        address old = registry;
        registry = pendingRegistry;
        pendingRegistry = address(0);
        registryUpdateTime = 0;
        emit RegistryUpdated(old, registry);
    }

    // ---------------------------------------------------------------------
    // Admin price setters
    // ---------------------------------------------------------------------

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setETHMintPrice(uint256 price) external onlyOwner {
        ethMintPrice = price;
        emit ETHMintPriceUpdated(price);
    }

    function setUSDCMintPrice(uint256 price) external onlyOwner {
        usdcMintPrice = price;
        emit USDCMintPriceUpdated(price);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _requireExists(uint256 tokenId) internal view {
        if (_ownerOf(tokenId) == address(0)) revert TokenNotExist();
    }
}
