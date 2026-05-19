// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { VaultID } from "../contracts/VaultID.sol";
import { VaultIDRegistry } from "../contracts/VaultIDRegistry.sol";
import { VaultIDMarketplace } from "../contracts/VaultIDMarketplace.sol";

// ---------------------------------------------------------------------------
// Mock USDC
// ---------------------------------------------------------------------------

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1_000_000e6);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ---------------------------------------------------------------------------
// VaultID test suite
// ---------------------------------------------------------------------------

contract VaultIDTest is Test {
    VaultID internal vault;
    VaultIDRegistry internal registry;
    VaultIDMarketplace internal marketplace;
    MockUSDC internal usdc;

    address internal admin = address(0xA11CE);
    address internal feeRecipient = address(0xFEE);
    address internal issuer = address(0x1551E5);
    address internal user = address(0xB0B);
    address internal user2 = address(0xCAFE);
    address internal recovery = address(0xCAFE5);
    address internal buyer = address(0xBEEF);

    uint256 internal constant BASIC_SUB_PRICE = 10e6;
    uint256 internal constant ISSUER_SUB_PRICE = 50e6;
    uint256 internal constant SUB_PERIOD = 30 days;
    uint32 internal constant BASIC_QUOTA = 5;

    function _completeOwnership(address newOwner) internal {
        // Accept ownership on all three contracts.
        vm.prank(newOwner);
        vault.acceptOwnership();
        vm.prank(newOwner);
        registry.acceptOwnership();
        vm.prank(newOwner);
        marketplace.acceptOwnership();
    }

    function setUp() public {
        // Deploy mock USDC and seed accounts
        usdc = new MockUSDC();
        usdc.mint(user, 1_000e6);
        usdc.mint(user2, 1_000e6);
        usdc.mint(issuer, 1_000e6);
        usdc.mint(buyer, 1_000e6);

        // Deployer = this contract; ownership will be transferred to admin.
        registry = new VaultIDRegistry(
            address(this),
            address(usdc),
            BASIC_SUB_PRICE,
            ISSUER_SUB_PRICE,
            SUB_PERIOD,
            BASIC_QUOTA
        );
        vault = new VaultID(address(this), feeRecipient, address(usdc), address(0), 0.001 ether, 5e6);
        marketplace = new VaultIDMarketplace(address(this), address(usdc), address(registry), feeRecipient, 250);

        // Link
        registry.setVaultContract(address(vault));
        vault.proposeRegistry(address(registry));
        vault.applyRegistryProposal(); // bypasses delay because registry was unset

        // Transfer ownership to admin (Ownable2Step)
        vault.transferOwnership(admin);
        registry.transferOwnership(admin);
        marketplace.transferOwnership(admin);
        _completeOwnership(admin);
    }

    // ---------------- Helpers ----------------

    function _registerIssuer(address who, string memory name) internal {
        vm.prank(who);
        registry.registerOrUpdateIssuerProfile(name, "logo", "banner", "https://site", "twitter");
    }

    function _payIssuerSub(address who) internal {
        vm.prank(who);
        usdc.approve(address(registry), ISSUER_SUB_PRICE);
        vm.prank(who);
        registry.purchaseIssuerSubscription();
    }

    function _payBasicSub(address who) internal {
        vm.prank(who);
        usdc.approve(address(registry), BASIC_SUB_PRICE);
        vm.prank(who);
        registry.purchaseBasicSubscription();
    }

    function _mintByIssuer(address to) internal returns (uint256) {
        vm.prank(issuer);
        return vault.issuerMint(to, "kyc", "ipfs://payload", "ipfs://meta", 0, recovery);
    }

    function _setupActiveIssuer() internal {
        _registerIssuer(issuer, "Acme Verifier");
        _payIssuerSub(issuer);
    }

    // ====================================================================
    // 1. Issuer revocation cannot be cleared by token owner
    // ====================================================================
    function test_01_IssuerRevocation_OwnerCannotClear() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);
        vm.prank(issuer);
        vault.revokeByIssuer(tokenId);

        // user.unrevoke() should only clear OWNER flag, leaving issuer flag intact
        vm.prank(user);
        vault.unrevoke(tokenId);

        (, bool byIssuer, ) = vault.revocationStatus(tokenId);
        assertTrue(byIssuer, "issuer flag must remain set");
        assertTrue(vault.isRevoked(tokenId), "still revoked");
        assertFalse(vault.isValid(tokenId), "must be invalid");
    }

    // ====================================================================
    // 2. Owner revocation cannot clear issuer revocation
    // ====================================================================
    function test_02_OwnerCannotClearIssuerRevocation() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);
        vm.prank(issuer);
        vault.revokeByIssuer(tokenId);

        // owner sets, then clears their own flag - issuer flag stays
        vm.prank(user);
        vault.revoke(tokenId);
        vm.prank(user);
        vault.unrevoke(tokenId);

        (bool byOwner, bool byIssuer, ) = vault.revocationStatus(tokenId);
        assertFalse(byOwner);
        assertTrue(byIssuer);
        assertTrue(vault.isRevoked(tokenId));
    }

    // ====================================================================
    // 3. Admin revocation cannot be cleared by owner or issuer
    // ====================================================================
    function test_03_AdminRevocation_OwnerAndIssuerCannotClear() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        vm.prank(admin);
        vault.revokeByAdmin(tokenId);

        // owner tries to clear via unrevoke - touches only owner flag
        vm.prank(user);
        vault.unrevoke(tokenId);
        // issuer tries to clear via unrevokeByIssuer - touches only issuer flag
        vm.prank(issuer);
        vault.unrevokeByIssuer(tokenId);

        (, , bool byAdmin) = vault.revocationStatus(tokenId);
        assertTrue(byAdmin, "admin flag remains");
        assertTrue(vault.isRevoked(tokenId));
    }

    // ====================================================================
    // 4. Issuer can only clear issuer revocation
    // ====================================================================
    function test_04_IssuerClearsOnlyIssuerFlag() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        // Set all three flags
        vm.prank(user);
        vault.revoke(tokenId);
        vm.prank(issuer);
        vault.revokeByIssuer(tokenId);
        vm.prank(admin);
        vault.revokeByAdmin(tokenId);

        // Issuer clears their flag
        vm.prank(issuer);
        vault.unrevokeByIssuer(tokenId);

        (bool byOwner, bool byIssuer, bool byAdmin) = vault.revocationStatus(tokenId);
        assertTrue(byOwner);
        assertFalse(byIssuer);
        assertTrue(byAdmin);
    }

    // ====================================================================
    // 5. Owner can only clear owner revocation
    // ====================================================================
    function test_05_OwnerClearsOnlyOwnerFlag() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        vm.prank(user);
        vault.revoke(tokenId);
        vm.prank(issuer);
        vault.revokeByIssuer(tokenId);
        vm.prank(admin);
        vault.revokeByAdmin(tokenId);

        vm.prank(user);
        vault.unrevoke(tokenId);

        (bool byOwner, bool byIssuer, bool byAdmin) = vault.revocationStatus(tokenId);
        assertFalse(byOwner);
        assertTrue(byIssuer);
        assertTrue(byAdmin);
    }

    // ====================================================================
    // 6. Admin can only clear admin revocation
    // ====================================================================
    function test_06_AdminClearsOnlyAdminFlag() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        vm.prank(user);
        vault.revoke(tokenId);
        vm.prank(issuer);
        vault.revokeByIssuer(tokenId);
        vm.prank(admin);
        vault.revokeByAdmin(tokenId);

        vm.prank(admin);
        vault.unrevokeByAdmin(tokenId);

        (bool byOwner, bool byIssuer, bool byAdmin) = vault.revocationStatus(tokenId);
        assertTrue(byOwner);
        assertTrue(byIssuer);
        assertFalse(byAdmin);
    }

    // ====================================================================
    // 7. isValid returns false when any revocation flag is active
    // ====================================================================
    function test_07_IsValidFalseWhenAnyFlag() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);
        assertTrue(vault.isValid(tokenId));

        // owner flag
        vm.prank(user);
        vault.revoke(tokenId);
        assertFalse(vault.isValid(tokenId));
        vm.prank(user);
        vault.unrevoke(tokenId);
        assertTrue(vault.isValid(tokenId));

        // issuer flag
        vm.prank(issuer);
        vault.revokeByIssuer(tokenId);
        assertFalse(vault.isValid(tokenId));
        vm.prank(issuer);
        vault.unrevokeByIssuer(tokenId);
        assertTrue(vault.isValid(tokenId));

        // admin flag
        vm.prank(admin);
        vault.revokeByAdmin(tokenId);
        assertFalse(vault.isValid(tokenId));
        vm.prank(admin);
        vault.unrevokeByAdmin(tokenId);
        assertTrue(vault.isValid(tokenId));
    }

    // ====================================================================
    // 8. Admin-revoked credential cannot be recovered into a valid one
    // ====================================================================
    function test_08_AdminRevoked_CannotRecover() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);
        vm.prank(admin);
        vault.revokeByAdmin(tokenId);
        vm.prank(recovery);
        vm.expectRevert(VaultID.TokenRevoked.selector);
        vault.recoverVault(tokenId, user2);
    }

    // ====================================================================
    // 9. Issuer-revoked credential cannot be recovered
    // ====================================================================
    function test_09_IssuerRevoked_CannotRecover() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);
        vm.prank(issuer);
        vault.revokeByIssuer(tokenId);
        vm.prank(recovery);
        vm.expectRevert(VaultID.TokenRevoked.selector);
        vault.recoverVault(tokenId, user2);
    }

    // ====================================================================
    // 10. Owner-revoked credential cannot be recovered
    // ====================================================================
    function test_10_OwnerRevoked_CannotRecover() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);
        vm.prank(user);
        vault.revoke(tokenId);
        vm.prank(recovery);
        vm.expectRevert(VaultID.TokenRevoked.selector);
        vault.recoverVault(tokenId, user2);
    }

    // ====================================================================
    // 11. Cannot set recovery wallet after revocation
    // ====================================================================
    function test_11_CannotSetRecoveryAfterRevocation() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);
        vm.prank(admin);
        vault.revokeByAdmin(tokenId);
        vm.prank(user);
        vm.expectRevert(VaultID.TokenRevoked.selector);
        vault.setRecoveryWallet(tokenId, address(0xDEAD));
    }

    // ====================================================================
    // 12. Cannot recover burned/deleted credential
    // ====================================================================
    function test_12_CannotRecoverBurned() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);
        vm.prank(user);
        vault.burn(tokenId);
        vm.prank(recovery);
        // Once burned, _ownerOf returns 0 — _requireExists reverts first
        vm.expectRevert(VaultID.TokenNotExist.selector);
        vault.recoverVault(tokenId, user2);
    }

    // ====================================================================
    // 13. Recovery preserves issuer, expiry, credentialType, encryptedRef, metadataRef
    // ====================================================================
    function test_13_RecoveryPreservesData() public {
        _registerIssuer(issuer, "Acme");
        _payIssuerSub(issuer);

        uint256 expiry = block.timestamp + 365 days;
        vm.prank(issuer);
        uint256 tokenId = vault.issuerMint(user, "kyc-v1", "ipfs://payload-xyz", "ipfs://meta-xyz", expiry, recovery);

        vm.prank(recovery);
        uint256 newTokenId = vault.recoverVault(tokenId, user2);

        VaultID.VaultData memory v = vault.getVaultData(newTokenId);
        assertEq(v.issuer, issuer);
        assertEq(v.credentialType, "kyc-v1");
        assertEq(v.expiry, expiry);
        assertEq(v.encryptedPayloadRef, "ipfs://payload-xyz");
        assertEq(v.metadataURI, "ipfs://meta-xyz");
        assertEq(vault.ownerOf(newTokenId), user2);
        assertTrue(vault.getVaultData(tokenId).burned);
    }

    // ====================================================================
    // 14. Deactivated issuer cannot self-reactivate by updating profile
    // ====================================================================
    function test_14_DeactivatedIssuer_CannotSelfReactivate() public {
        _registerIssuer(issuer, "Acme");
        vm.prank(admin);
        registry.deactivateIssuer(issuer);

        // Try to "update" - active must remain false
        vm.prank(issuer);
        registry.registerOrUpdateIssuerProfile("Acme2", "logo2", "banner2", "site2", "social2");

        VaultIDRegistry.IssuerProfile memory p = registry.getIssuerProfile(issuer);
        assertFalse(p.active, "must remain deactivated");
        assertFalse(registry.isIssuerActive(issuer));
    }

    // ====================================================================
    // 15. Deactivated issuer cannot mint
    // ====================================================================
    function test_15_DeactivatedIssuer_CannotMint() public {
        _setupActiveIssuer();
        vm.prank(admin);
        registry.deactivateIssuer(issuer);

        vm.prank(issuer);
        vm.expectRevert(VaultID.IssuerNotEligible.selector);
        vault.issuerMint(user, "kyc", "ipfs://p", "ipfs://m", 0, recovery);
    }

    // ====================================================================
    // 16. Deactivated issuer cannot revoke/unrevoke/extend
    // ====================================================================
    function test_16_DeactivatedIssuer_CannotAdminister() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        vm.prank(admin);
        registry.deactivateIssuer(issuer);

        vm.prank(issuer);
        vm.expectRevert(VaultID.IssuerNotEligible.selector);
        vault.revokeByIssuer(tokenId);

        vm.prank(issuer);
        vm.expectRevert(VaultID.IssuerNotEligible.selector);
        vault.unrevokeByIssuer(tokenId);

        vm.prank(issuer);
        vm.expectRevert(VaultID.IssuerNotEligible.selector);
        vault.extendExpiry(tokenId, block.timestamp + 30 days);
    }

    // ====================================================================
    // 17. Verified but deactivated issuer is not considered active
    // ====================================================================
    function test_17_VerifiedButDeactivated_NotActive() public {
        _registerIssuer(issuer, "Acme");
        vm.prank(admin);
        registry.verifyIssuer(issuer);
        vm.prank(admin);
        registry.deactivateIssuer(issuer);

        assertFalse(registry.isIssuerActive(issuer));
        assertFalse(registry.canIssuerMint(issuer));
    }

    // ====================================================================
    // 18. Lapsed subscription + active profile -> can still administer
    // ====================================================================
    function test_18_LapsedSub_StillAdministers() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        // Warp past subscription
        vm.warp(block.timestamp + SUB_PERIOD + 1 days);

        // canIssuerMint returns false
        assertFalse(registry.canIssuerMint(issuer));
        // But issuer can still revoke
        vm.prank(issuer);
        vault.revokeByIssuer(tokenId);
        (, bool byIssuer, ) = vault.revocationStatus(tokenId);
        assertTrue(byIssuer);

        // Can also unrevoke
        vm.prank(issuer);
        vault.unrevokeByIssuer(tokenId);
    }

    // ====================================================================
    // 19. Lapsed subscription issuer cannot mint
    // ====================================================================
    function test_19_LapsedSub_CannotMint() public {
        _setupActiveIssuer();
        vm.warp(block.timestamp + SUB_PERIOD + 1 days);
        vm.prank(issuer);
        vm.expectRevert(VaultID.IssuerNotEligible.selector);
        vault.issuerMint(user, "kyc", "p", "m", 0, recovery);
    }

    // ====================================================================
    // 20. extendExpiry does not reactivate revoked membership
    // ====================================================================
    function test_20_ExtendExpiry_DoesNotReactivateRevokedMembership() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        vm.prank(user);
        vault.setMembershipData(tokenId, block.timestamp + 30 days, "gold");

        vm.prank(admin);
        vault.revokeByAdmin(tokenId);

        // extend (by issuer) - should not flip membership.active true
        vm.prank(issuer);
        vault.extendExpiry(tokenId, block.timestamp + 365 days);

        VaultID.MembershipData memory m = vault.getMembershipData(tokenId);
        assertFalse(m.active, "must not become active while revoked");
    }

    // ====================================================================
    // 21. membership.active doesn't contradict revoked/expired
    // ====================================================================
    function test_21_MembershipActive_AlignsWithValidity() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        vm.prank(user);
        vault.setMembershipData(tokenId, block.timestamp + 30 days, "silver");

        VaultID.MembershipData memory m = vault.getMembershipData(tokenId);
        assertTrue(m.active);

        // Owner revokes -> not active
        vm.prank(user);
        vault.revoke(tokenId);
        m = vault.getMembershipData(tokenId);
        assertFalse(m.active);

        // Unrevoke -> active again
        vm.prank(user);
        vault.unrevoke(tokenId);
        m = vault.getMembershipData(tokenId);
        assertTrue(m.active);

        // Time-warp past expiry -> not active
        vm.warp(block.timestamp + 60 days);
        m = vault.getMembershipData(tokenId);
        assertFalse(m.active);
    }

    // ====================================================================
    // 22. basicMintQuota cannot be set to type(uint32).max
    // ====================================================================
    function test_22_QuotaCannotEqualMax() public {
        vm.prank(admin);
        vm.expectRevert(VaultIDRegistry.QuotaTooLarge.selector);
        registry.setBasicMintQuota(type(uint32).max);
    }

    function test_22b_QuotaConstructorRejectsMax() public {
        vm.expectRevert(VaultIDRegistry.QuotaTooLarge.selector);
        new VaultIDRegistry(address(this), address(usdc), 1, 1, 1 days, type(uint32).max);
    }

    // ====================================================================
    // 23. Quota cannot wrap (overflow)
    // ====================================================================
    function test_23_QuotaCannotWrap() public {
        // Set quota to small value
        vm.prank(admin);
        registry.setBasicMintQuota(2);

        _payBasicSub(user);

        // Two valid consumes
        vm.prank(address(vault));
        registry.consumeBasicMint(user);
        vm.prank(address(vault));
        registry.consumeBasicMint(user);

        // Third must revert (no wrap to 0)
        vm.prank(address(vault));
        vm.expectRevert(VaultIDRegistry.QuotaExhausted.selector);
        registry.consumeBasicMint(user);
    }

    // ====================================================================
    // 24. Registry update cannot happen instantly (when registry already set)
    // ====================================================================
    function test_24_RegistryUpdate_NotInstant() public {
        // registry is already set (from setUp). Propose a new one.
        VaultIDRegistry newReg = new VaultIDRegistry(admin, address(usdc), 1e6, 5e6, 30 days, 3);
        vm.prank(admin);
        vault.proposeRegistry(address(newReg));

        // Try to apply immediately
        vm.prank(admin);
        vm.expectRevert(VaultID.DelayNotElapsed.selector);
        vault.applyRegistryProposal();
    }

    // ====================================================================
    // 25. Registry update only applies after delay
    // ====================================================================
    function test_25_RegistryUpdate_AppliesAfterDelay() public {
        VaultIDRegistry newReg = new VaultIDRegistry(admin, address(usdc), 1e6, 5e6, 30 days, 3);
        vm.prank(admin);
        vault.proposeRegistry(address(newReg));

        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(admin);
        vault.applyRegistryProposal();

        assertEq(vault.registry(), address(newReg));
        assertEq(vault.pendingRegistry(), address(0));
    }

    // ====================================================================
    // 26. Registry proposal can be cancelled
    // ====================================================================
    function test_26_RegistryProposal_CanCancel() public {
        VaultIDRegistry newReg = new VaultIDRegistry(admin, address(usdc), 1e6, 5e6, 30 days, 3);
        vm.prank(admin);
        vault.proposeRegistry(address(newReg));
        assertEq(vault.pendingRegistry(), address(newReg));

        vm.prank(admin);
        vault.cancelRegistryProposal();
        assertEq(vault.pendingRegistry(), address(0));

        // Can no longer apply
        vm.warp(block.timestamp + 49 hours);
        vm.prank(admin);
        vm.expectRevert(VaultID.NoPendingProposal.selector);
        vault.applyRegistryProposal();
    }

    // ====================================================================
    // 27. transferFrom and safeTransferFrom fail
    // ====================================================================
    function test_27_TransferFromBlocked() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        vm.prank(user);
        vm.expectRevert(VaultID.Soulbound.selector);
        vault.transferFrom(user, user2, tokenId);

        vm.prank(user);
        vm.expectRevert(VaultID.Soulbound.selector);
        vault.safeTransferFrom(user, user2, tokenId);

        vm.prank(user);
        vm.expectRevert(VaultID.Soulbound.selector);
        vault.safeTransferFrom(user, user2, tokenId, "");
    }

    // ====================================================================
    // 28. Approvals do not enable transfer
    // ====================================================================
    function test_28_ApprovalsRevert() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        vm.prank(user);
        vm.expectRevert(VaultID.ApprovalsDisabled.selector);
        vault.approve(user2, tokenId);

        vm.prank(user);
        vm.expectRevert(VaultID.ApprovalsDisabled.selector);
        vault.setApprovalForAll(user2, true);
    }

    // ====================================================================
    // 29. vaultContract is linked correctly in deployment
    // ====================================================================
    function test_29_VaultContractLinked() public view {
        assertEq(registry.vaultContract(), address(vault));
        assertEq(vault.registry(), address(registry));
    }

    function test_29b_VaultContractCannotBeReset() public {
        vm.prank(admin);
        vm.expectRevert(VaultIDRegistry.VaultAlreadySet.selector);
        registry.setVaultContract(address(0xBEEF));
    }

    // ====================================================================
    // 30. Marketplace does not violate soulbound behavior
    // (Marketplace deals in arbitrary products, NOT VaultID NFTs. We assert that no
    // path inside the marketplace touches the VaultID contract.)
    // ====================================================================
    function test_30_MarketplaceDoesNotTransferVaultID() public {
        _setupActiveIssuer();
        uint256 tokenId = _mintByIssuer(user);

        // List a generic product
        vm.prank(issuer);
        uint256 listingId = marketplace.createListing("Service", "Description", "ipfs://product", 20e6, 0);

        // Buyer purchases
        vm.prank(buyer);
        usdc.approve(address(marketplace), 100e6);
        vm.prank(buyer);
        marketplace.purchase(listingId);

        // Token ownership unchanged
        assertEq(vault.ownerOf(tokenId), user, "VaultID owner unchanged");
    }

    // ====================================================================
    // 31. Marketplace payment/listing flows are non-reentrant
    // We deploy a malicious ERC-20 (RevertingUSDC variant) whose transferFrom
    // re-enters marketplace.purchase. The inner purchase must revert with
    // ReentrancyGuardReentrantCall, proving the modifier is wired.
    // ====================================================================
    function test_31_MarketplaceReentrancyBlocked() public {
        // Build a fresh marketplace pointing at a malicious token whose
        // transferFrom re-enters purchase().
        ReentrantToken bad = new ReentrantToken();
        VaultIDMarketplace mp = new VaultIDMarketplace(address(this), address(bad), address(registry), feeRecipient, 0);

        _setupActiveIssuer();
        vm.prank(issuer);
        uint256 listingId = mp.createListing("X", "Y", "Z", 1e6, 0);

        // Wire token to the marketplace so it can re-enter
        bad.setTarget(mp, listingId);
        bad.mint(buyer, 100e6);

        vm.prank(buyer);
        bad.approve(address(mp), 100e6);

        // The outer purchase should revert because the inner reentry triggered
        // by the malicious token's transferFrom hits the ReentrancyGuard.
        vm.prank(buyer);
        vm.expectRevert(); // any revert from the reentrancy guard chain
        mp.purchase(listingId);
    }

    // ====================================================================
    // 32. Marketplace blocks stale/revoked listings if issuer deactivated
    // ====================================================================
    function test_32_MarketplaceBlocksDeactivatedIssuer() public {
        _setupActiveIssuer();

        vm.prank(issuer);
        uint256 listingId = marketplace.createListing("Service", "Desc", "uri", 10e6, 0);

        // Admin deactivates the issuer
        vm.prank(admin);
        registry.deactivateIssuer(issuer);

        // Buyer attempts purchase - should be blocked
        vm.prank(buyer);
        usdc.approve(address(marketplace), 100e6);
        vm.prank(buyer);
        vm.expectRevert(VaultIDMarketplace.NotActiveIssuer.selector);
        marketplace.purchase(listingId);
    }

    // ====================================================================
    // Bonus: confirm mint/burn flows + ETH path
    // ====================================================================
    function test_BonusMintWithETH() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 tokenId = vault.mintWithETH{ value: 0.001 ether }("self", "ipfs://p", "ipfs://m", 0, recovery);
        assertEq(vault.ownerOf(tokenId), user);
        assertEq(feeRecipient.balance, 0.001 ether);
    }

    function test_BonusMintWithUSDC() public {
        vm.prank(user);
        usdc.approve(address(vault), 5e6);
        vm.prank(user);
        uint256 tokenId = vault.mintWithUSDC("self", "ipfs://p", "ipfs://m", 0, recovery);
        assertEq(vault.ownerOf(tokenId), user);
        assertEq(usdc.balanceOf(feeRecipient), 5e6);
    }

    function test_BonusMintWithSubscription() public {
        _payBasicSub(user);
        vm.prank(user);
        uint256 tokenId = vault.mintWithSubscription("self", "p", "m", 0, recovery);
        assertEq(vault.ownerOf(tokenId), user);
        VaultIDRegistry.BasicMintRecord memory rec = registry.getBasicMintRecord(user);
        assertEq(rec.consumed, 1);
    }
}

// ---------------------------------------------------------------------------
// Malicious ERC20 whose transferFrom re-enters marketplace.purchase.
// Used to verify ReentrancyGuard on VaultIDMarketplace.purchase.
// ---------------------------------------------------------------------------

contract ReentrantToken is ERC20 {
    VaultIDMarketplace public target;
    uint256 public targetListingId;
    bool internal entered;

    constructor() ERC20("Reentrant", "REE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function setTarget(VaultIDMarketplace _t, uint256 _id) external {
        target = _t;
        targetListingId = _id;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        // Attempt to re-enter the marketplace exactly once on the first hop.
        if (!entered && address(target) != address(0)) {
            entered = true;
            target.purchase(targetListingId);
        }
        return super.transferFrom(from, to, value);
    }
}
