// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VaultIDMarketplace
 * @notice Issuer storefront for products/services purchased in USDC. Does NOT transfer
 *         any VaultID NFTs (they are soulbound).
 */
contract VaultIDMarketplace is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Listing {
        address issuer;
        string productName;
        string productDescription;
        string productURI;
        uint256 priceUSDC;
        bool active;
        uint256 maxUnits; // 0 = unlimited
        uint256 soldUnits;
    }

    IERC20 public immutable USDC;
    address public feeRecipient;
    uint256 public feePercent; // basis points (max 1000 = 10%)

    mapping(uint256 => Listing) public listings;
    uint256 public nextListingId;

    address public registry;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ListingCreated(uint256 indexed listingId, address indexed issuer, string productName, uint256 priceUSDC);
    event ListingUpdated(uint256 indexed listingId);
    event ListingDeactivated(uint256 indexed listingId);
    event ProductPurchased(uint256 indexed listingId, address indexed buyer, uint256 priceUSDC);
    event FeeRecipientUpdated(address newFeeRecipient);
    event FeePercentUpdated(uint256 newFeePercent);
    event RegistryUpdated(address newRegistry);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidAddress();
    error FeeTooHigh();
    error NotActiveIssuer();
    error NotListingIssuer();
    error NotAuthorized();
    error ListingInactive();
    error SoldOut();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        address _owner,
        address _usdc,
        address _registry,
        address _feeRecipient,
        uint256 _feePercent
    ) Ownable(_owner) {
        if (_usdc == address(0)) revert InvalidAddress();
        if (_feeRecipient == address(0)) revert InvalidAddress();
        if (_feePercent > 1000) revert FeeTooHigh();

        USDC = IERC20(_usdc);
        registry = _registry;
        feeRecipient = _feeRecipient;
        feePercent = _feePercent;
    }

    // ---------------------------------------------------------------------
    // Listings
    // ---------------------------------------------------------------------

    function createListing(
        string calldata productName,
        string calldata productDescription,
        string calldata productUri,
        uint256 priceUSDC,
        uint256 maxUnits
    ) external nonReentrant returns (uint256 listingId) {
        if (!_isIssuerActive(msg.sender)) revert NotActiveIssuer();
        listingId = nextListingId++;
        listings[listingId] = Listing({
            issuer: msg.sender,
            productName: productName,
            productDescription: productDescription,
            productURI: productUri,
            priceUSDC: priceUSDC,
            active: true,
            maxUnits: maxUnits,
            soldUnits: 0
        });
        emit ListingCreated(listingId, msg.sender, productName, priceUSDC);
    }

    function updateListing(
        uint256 listingId,
        string calldata productName,
        string calldata productDescription,
        string calldata productUri,
        uint256 priceUSDC
    ) external nonReentrant {
        Listing storage l = listings[listingId];
        if (l.issuer != msg.sender) revert NotListingIssuer();
        if (!l.active) revert ListingInactive();
        l.productName = productName;
        l.productDescription = productDescription;
        l.productURI = productUri;
        l.priceUSDC = priceUSDC;
        emit ListingUpdated(listingId);
    }

    function deactivateListing(uint256 listingId) external {
        Listing storage l = listings[listingId];
        if (l.issuer != msg.sender && owner() != msg.sender) revert NotAuthorized();
        l.active = false;
        emit ListingDeactivated(listingId);
    }

    function purchase(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        if (!l.active) revert ListingInactive();
        if (!_isIssuerActive(l.issuer)) revert NotActiveIssuer();
        if (l.maxUnits != 0 && l.soldUnits >= l.maxUnits) revert SoldOut();

        l.soldUnits += 1;

        uint256 price = l.priceUSDC;
        uint256 fee = (price * feePercent) / 10_000;
        uint256 issuerAmount = price - fee;

        if (fee > 0) {
            USDC.safeTransferFrom(msg.sender, feeRecipient, fee);
        }
        if (issuerAmount > 0) {
            USDC.safeTransferFrom(msg.sender, l.issuer, issuerAmount);
        }

        emit ProductPurchased(listingId, msg.sender, price);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert InvalidAddress();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    function setFeePercent(uint256 newFeePercent) external onlyOwner {
        if (newFeePercent > 1000) revert FeeTooHigh();
        feePercent = newFeePercent;
        emit FeePercentUpdated(newFeePercent);
    }

    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert InvalidAddress();
        registry = newRegistry;
        emit RegistryUpdated(newRegistry);
    }

    // ---------------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------------

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    function _isIssuerActive(address issuer) internal view returns (bool) {
        if (registry == address(0)) return false;
        (bool success, bytes memory data) = registry.staticcall(
            abi.encodeWithSignature("isIssuerActive(address)", issuer)
        );
        if (!success || data.length < 32) return false;
        return abi.decode(data, (bool));
    }
}
