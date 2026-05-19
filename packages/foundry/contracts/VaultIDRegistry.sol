// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VaultIDRegistry
 * @notice Manages issuer profiles, basic / issuer subscriptions, and basic mint quotas.
 */
contract VaultIDRegistry is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct IssuerProfile {
        bool exists;
        bool active; // admin-controlled, NOT self-settable after deactivation
        bool verified; // admin-only
        string name;
        string logoURI;
        string bannerURI;
        string website;
        string social;
        uint256 registeredAt;
    }

    struct Subscription {
        bool active;
        uint256 paidThrough; // timestamp until subscription is paid
        uint256 tier; // 0 = none, 1 = basic, 2 = issuer
    }

    struct BasicMintRecord {
        uint32 consumed;
        uint32 quota; // snapshot of basicMintQuota at subscription purchase time
    }

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    mapping(address => IssuerProfile) public issuerProfiles;
    mapping(address => Subscription) public basicSubscriptions;
    mapping(address => Subscription) public issuerSubscriptions;
    mapping(address => BasicMintRecord) public basicMintRecords;

    uint256 public basicSubscriptionPrice; // in USDC (6 decimals)
    uint256 public issuerSubscriptionPrice; // in USDC (6 decimals)
    uint256 public subscriptionPeriod; // seconds (e.g. 30 days)

    uint32 public basicMintQuota; // per subscription period

    address public immutable USDC_ADDRESS;
    address public vaultContract;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event IssuerProfileRegistered(address indexed issuer, string name);
    event IssuerProfileUpdated(address indexed issuer, string name);
    event IssuerVerified(address indexed issuer);
    event IssuerUnverified(address indexed issuer);
    event IssuerDeactivated(address indexed issuer);
    event IssuerReactivated(address indexed issuer);

    event SubscriptionPurchased(address indexed subscriber, uint256 tier, uint256 paidThrough);
    event SubscriptionCancelled(address indexed subscriber);

    event BasicMintConsumed(address indexed subscriber);
    event BasicMintQuotaUpdated(uint32 quota);
    event BasicSubscriptionPriceUpdated(uint256 price);
    event IssuerSubscriptionPriceUpdated(uint256 price);
    event SubscriptionPeriodUpdated(uint256 period);

    event VaultContractSet(address indexed vault);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidAddress();
    error InvalidName();
    error NotVault();
    error QuotaExhausted();
    error QuotaTooLarge();
    error VaultAlreadySet();
    error NoActiveSubscription();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyVaultContract() {
        if (msg.sender != vaultContract) revert NotVault();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        address _owner,
        address _usdcAddress,
        uint256 _basicSubscriptionPrice,
        uint256 _issuerSubscriptionPrice,
        uint256 _subscriptionPeriod,
        uint32 _basicMintQuota
    ) Ownable(_owner) {
        if (_usdcAddress == address(0)) revert InvalidAddress();
        if (_basicMintQuota >= type(uint32).max) revert QuotaTooLarge();

        USDC_ADDRESS = _usdcAddress;
        basicSubscriptionPrice = _basicSubscriptionPrice;
        issuerSubscriptionPrice = _issuerSubscriptionPrice;
        subscriptionPeriod = _subscriptionPeriod;
        basicMintQuota = _basicMintQuota;
    }

    // ---------------------------------------------------------------------
    // Issuer profile lifecycle
    // ---------------------------------------------------------------------

    /**
     * @notice Register a new issuer profile or update an existing one.
     * @dev On first registration, sets active = true. On updates, can NEVER set
     *      active = true (only admin can re-activate via {reactivateIssuer}).
     */
    function registerOrUpdateIssuerProfile(
        string calldata name,
        string calldata logoURI,
        string calldata bannerURI,
        string calldata website,
        string calldata social
    ) external {
        if (bytes(name).length == 0) revert InvalidName();

        IssuerProfile storage p = issuerProfiles[msg.sender];

        if (!p.exists) {
            // First registration
            p.exists = true;
            p.active = true;
            p.registeredAt = block.timestamp;
            p.name = name;
            p.logoURI = logoURI;
            p.bannerURI = bannerURI;
            p.website = website;
            p.social = social;
            emit IssuerProfileRegistered(msg.sender, name);
        } else {
            // Update: NEVER reactivate
            p.name = name;
            p.logoURI = logoURI;
            p.bannerURI = bannerURI;
            p.website = website;
            p.social = social;
            // p.active intentionally untouched
            emit IssuerProfileUpdated(msg.sender, name);
        }
    }

    function verifyIssuer(address issuer) external onlyOwner {
        IssuerProfile storage p = issuerProfiles[issuer];
        p.verified = true;
        emit IssuerVerified(issuer);
    }

    function unverifyIssuer(address issuer) external onlyOwner {
        IssuerProfile storage p = issuerProfiles[issuer];
        p.verified = false;
        emit IssuerUnverified(issuer);
    }

    function deactivateIssuer(address issuer) external onlyOwner {
        IssuerProfile storage p = issuerProfiles[issuer];
        p.active = false;
        emit IssuerDeactivated(issuer);
    }

    function reactivateIssuer(address issuer) external onlyOwner {
        IssuerProfile storage p = issuerProfiles[issuer];
        if (!p.exists) revert InvalidAddress();
        p.active = true;
        emit IssuerReactivated(issuer);
    }

    // ---------------------------------------------------------------------
    // Subscriptions
    // ---------------------------------------------------------------------

    function purchaseBasicSubscription() external nonReentrant {
        IERC20(USDC_ADDRESS).safeTransferFrom(msg.sender, owner(), basicSubscriptionPrice);

        Subscription storage sub = basicSubscriptions[msg.sender];
        uint256 base = sub.paidThrough > block.timestamp ? sub.paidThrough : block.timestamp;
        sub.paidThrough = base + subscriptionPeriod;
        sub.active = true;
        sub.tier = 1;

        // Snapshot quota for this purchase period; reset consumed counter.
        BasicMintRecord storage rec = basicMintRecords[msg.sender];
        rec.consumed = 0;
        rec.quota = basicMintQuota;

        emit SubscriptionPurchased(msg.sender, 1, sub.paidThrough);
    }

    function purchaseIssuerSubscription() external nonReentrant {
        IERC20(USDC_ADDRESS).safeTransferFrom(msg.sender, owner(), issuerSubscriptionPrice);

        Subscription storage sub = issuerSubscriptions[msg.sender];
        uint256 base = sub.paidThrough > block.timestamp ? sub.paidThrough : block.timestamp;
        sub.paidThrough = base + subscriptionPeriod;
        sub.active = true;
        sub.tier = 2;

        emit SubscriptionPurchased(msg.sender, 2, sub.paidThrough);
    }

    function cancelSubscription() external {
        Subscription storage basic = basicSubscriptions[msg.sender];
        Subscription storage issuerSub = issuerSubscriptions[msg.sender];

        if (!basic.active && !issuerSub.active) revert NoActiveSubscription();

        basic.active = false;
        issuerSub.active = false;
        emit SubscriptionCancelled(msg.sender);
    }

    // ---------------------------------------------------------------------
    // Mint quotas
    // ---------------------------------------------------------------------

    function setBasicMintQuota(uint32 quota) external onlyOwner {
        if (quota >= type(uint32).max) revert QuotaTooLarge();
        basicMintQuota = quota;
        emit BasicMintQuotaUpdated(quota);
    }

    /**
     * @notice Consume one mint from a subscriber's basic quota.
     * @dev Called only by the linked VaultID contract during mintWithSubscription.
     */
    function consumeBasicMint(address subscriber) external onlyVaultContract {
        Subscription storage sub = basicSubscriptions[subscriber];
        if (!sub.active || sub.paidThrough < block.timestamp) revert NoActiveSubscription();

        BasicMintRecord storage rec = basicMintRecords[subscriber];

        // Defensive overflow check (cannot occur given quota cap, but explicit).
        if (rec.consumed >= rec.quota) revert QuotaExhausted();
        if (rec.consumed == type(uint32).max) revert QuotaExhausted();

        unchecked {
            rec.consumed = rec.consumed + 1;
        }
        emit BasicMintConsumed(subscriber);
    }

    // ---------------------------------------------------------------------
    // Vault linkage
    // ---------------------------------------------------------------------

    function setVaultContract(address _vault) external onlyOwner {
        if (_vault == address(0)) revert InvalidAddress();
        if (vaultContract != address(0)) revert VaultAlreadySet();
        vaultContract = _vault;
        emit VaultContractSet(_vault);
    }

    // ---------------------------------------------------------------------
    // Admin price setters
    // ---------------------------------------------------------------------

    function setBasicSubscriptionPrice(uint256 price) external onlyOwner {
        basicSubscriptionPrice = price;
        emit BasicSubscriptionPriceUpdated(price);
    }

    function setIssuerSubscriptionPrice(uint256 price) external onlyOwner {
        issuerSubscriptionPrice = price;
        emit IssuerSubscriptionPriceUpdated(price);
    }

    function setSubscriptionPeriod(uint256 period) external onlyOwner {
        subscriptionPeriod = period;
        emit SubscriptionPeriodUpdated(period);
    }

    // ---------------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------------

    /// @notice Issuer is "active" only with an existing, admin-active profile and a non-empty name.
    function isIssuerActive(address issuer) external view returns (bool) {
        IssuerProfile storage p = issuerProfiles[issuer];
        return p.exists && p.active && bytes(p.name).length > 0;
    }

    /// @notice True if the issuer can MINT new credentials right now.
    function canIssuerMint(address issuer) external view returns (bool) {
        IssuerProfile storage p = issuerProfiles[issuer];
        if (!(p.exists && p.active && bytes(p.name).length > 0)) return false;
        Subscription storage sub = issuerSubscriptions[issuer];
        return sub.active && sub.paidThrough >= block.timestamp;
    }

    function hasActiveBasicSubscription(address subscriber) external view returns (bool) {
        Subscription storage sub = basicSubscriptions[subscriber];
        return sub.active && sub.paidThrough >= block.timestamp;
    }

    /**
     * @notice Whether the issuer retains administrative rights over previously-issued credentials.
     * @dev Lapsed subscription is OK — only admin-deactivation removes admin rights.
     */
    function issuerAdminRights(address issuer) external view returns (bool) {
        IssuerProfile storage p = issuerProfiles[issuer];
        return p.exists && p.active;
    }

    function getIssuerProfile(address issuer) external view returns (IssuerProfile memory) {
        return issuerProfiles[issuer];
    }

    function getBasicSubscription(address subscriber) external view returns (Subscription memory) {
        return basicSubscriptions[subscriber];
    }

    function getIssuerSubscription(address issuer) external view returns (Subscription memory) {
        return issuerSubscriptions[issuer];
    }

    function getBasicMintRecord(address subscriber) external view returns (BasicMintRecord memory) {
        return basicMintRecords[subscriber];
    }
}
