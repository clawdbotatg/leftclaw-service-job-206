# VaultID Production Deployment Report

**Deployed:** May 19, 2026  
**Network:** Base Mainnet (Chain ID: 8453)  
**GitHub:** https://github.com/clawdbotatg/leftclaw-service-job-206  

---

## Contract Addresses

| Contract | Address | Basescan |
|----------|---------|---------|
| **VaultID** | `0xcD6f94479De82dc8237CFD2192639cd7A6F086e4` | [View](https://basescan.org/address/0xcd6f94479de82dc8237cfd2192639cd7a6f086e4#code) |
| **VaultIDRegistry** | `0x83c43535674C79925908dc6E67eB88B2af1E786e` | [View](https://basescan.org/address/0x83c43535674c79925908dc6e67eb88b2af1e786e#code) |
| **VaultIDMarketplace** | `0x461b29660aa4E48bC9d10f7c2BF0280B0FC1E28b` | [View](https://basescan.org/address/0x461b29660aa4e48bc9d10f7c2bf0280b0fc1e28b#code) |

All three contracts are **verified** on Basescan (source code readable, ABI available).

---

## Constructor Arguments

### VaultIDRegistry
- `_owner`: `0xB2109c9C0BbA5F7e99b30B304968bD22925621AD` (deployer, pending transfer)
- `_usdcAddress`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (USDC on Base)
- `_basicSubscriptionPrice`: `10,000,000` (10 USDC)
- `_issuerSubscriptionPrice`: `50,000,000` (50 USDC)
- `_subscriptionPeriod`: `2,592,000` (30 days)
- `_basicMintQuota`: `5`

### VaultID
- `_owner`: `0xB2109c9C0BbA5F7e99b30B304968bD22925621AD` (deployer, pending transfer)
- `_feeRecipient`: `0xFE968dE21eb0E77d5877477C31a04A3075c0086E` (client wallet)
- `_usdcAddress`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (USDC on Base)
- `_clawdAddress`: `0x0000000000000000000000000000000000000000` (not configured)
- `_ethMintPrice`: `1,000,000,000,000,000` (0.001 ETH)
- `_usdcMintPrice`: `5,000,000` (5 USDC)

### VaultIDMarketplace
- `_owner`: `0xB2109c9C0BbA5F7e99b30B304968bD22925621AD` (deployer, pending transfer)
- `_usdc`: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (USDC on Base)
- `_registry`: `0x83c43535674C79925908dc6E67eB88B2af1E786e`
- `_feeRecipient`: `0xFE968dE21eb0E77d5877477C31a04A3075c0086E` (client wallet)
- `_feePercent`: `250` (2.5% in basis points)

---

## Ownership Status

**All three contracts use Ownable2Step.** The deployer called `transferOwnership(0xFE968dE21eb0E77d5877477C31a04A3075c0086E)` for all three contracts.

**ACTION REQUIRED:** The client must call `acceptOwnership()` on each contract from their wallet (`0xFE968dE21eb0E77d5877477C31a04A3075c0086E`).

```bash
# From client wallet (0xFE968dE21eb0E77d5877477C31a04A3075c0086E):
cast send 0xcD6f94479De82dc8237CFD2192639cd7A6F086e4 "acceptOwnership()" --rpc-url https://mainnet.base.org
cast send 0x83c43535674C79925908dc6E67eB88B2af1E786e "acceptOwnership()" --rpc-url https://mainnet.base.org
cast send 0x461b29660aa4E48bC9d10f7c2BF0280B0FC1E28b "acceptOwnership()" --rpc-url https://mainnet.base.org
```

---

## Contract Linkage

- **Registry → VaultID**: `registry.vaultContract` = `0xcD6f94479De82dc8237CFD2192639cd7A6F086e4` ✓
- **VaultID → Registry**: `vaultId.registry` = `0x83c43535674C79925908dc6E67eB88B2af1E786e` ✓

---

## Audit Findings Fixed

### HIGH 1 — Issuer Revocation Bypass ✓ FIXED
**Fix:** Replaced single `revoked` boolean with three separate flags: `revokedByOwner`, `revokedByIssuer`, `revokedByAdmin`. Each actor can only set and clear their own flag. The `unrevoke()` function only clears `revokedByOwner`. `unrevokeByIssuer()` only clears `revokedByIssuer`. `unrevokeByAdmin()` only clears `revokedByAdmin`. No actor can clear another actor's flag.

**Invariant guaranteed:** If an issuer revokes a credential, the token owner cannot make it valid again.

### HIGH 2 — Admin Revocation Bypass Through Recovery ✓ FIXED  
**Fix:** `recoverVault()` now checks `isRevoked(tokenId)` and `vaultData.burned` at the top and reverts if either is true. Recovery cannot bypass any revocation flag. `setRecoveryWallet()` also checks revocation before allowing changes.

**Invariant guaranteed:** A revoked credential cannot become valid again through recovery.

### HIGH 3 — Admin-Deactivated Issuer Can Self-Reactivate ✓ FIXED
**Fix:** `registerOrUpdateIssuerProfile()` sets `active = true` only when `!p.exists` (first registration). For existing profiles, `active` is intentionally left unchanged. Only `reactivateIssuer()` (owner-only) can set `active = true` for an existing profile.

**Invariant guaranteed:** If admin deactivates an issuer, the issuer cannot self-reactivate.

### MEDIUM 1 — Instant Registry Swap ✓ FIXED
**Fix:** 2-step process with `proposeRegistry()` → `applyRegistryProposal()` after `REGISTRY_UPDATE_DELAY = 48 hours`. Initial setup bypasses delay only when `registry == address(0)`. Events `RegistryUpdateProposed`, `RegistryUpdateCancelled`, `RegistryUpdated` are emitted.

### MEDIUM 2 — Lapsed Issuer Administrative Rights ✓ IMPLEMENTED
**Decision (per spec):** `issuerAdminRights(address issuer)` returns true if `profile.exists && profile.active`. A lapsed subscription does NOT remove admin rights over previously issued credentials. Only admin deactivation removes rights. New minting still requires active issuer subscription.

### LOW 1 — extendExpiry Reactivates Revoked Membership State ✓ FIXED
**Fix:** `extendExpiry()` updates the expiry timestamp but `membership.active` is always derived (never stored as a static `true`). The `getMembershipData()` getter computes `active` as: `exists && membershipExpiry > block.timestamp && !isRevoked(tokenId) && !vaultData.burned`.

### LOW 2 — USDC Blocklist DoS ✓ ADDRESSED
**Fix:** `feeRecipient` is owner-updateable via `setFeeRecipient()`. Added comment documenting the consideration. SafeERC20 is used throughout.

### LOW 3 — Unchecked Mint Counter Wrap ✓ FIXED
**Fix:** `setBasicMintQuota()` requires `quota < type(uint32).max`. Constructor also validates this. The quota consumed counter is explicitly checked against `type(uint32).max` before incrementing.

### INFO 1 — PUSH0 on Base
No action needed for Base (as specified).

### INFO 2 — vaultContract Unset at Deployment ✓ FIXED
**Fix:** Deployment script calls `registry.setVaultContract(address(vaultId))` and `vaultId.proposeRegistry(address(registry))` + `vaultId.applyRegistryProposal()` in the same transaction. Both contracts are linked before ownership is transferred.

### INFO 3 — setBackupWallet Alias
**Fix:** Only `setRecoveryWallet` naming is used. No backward compatibility alias retained (not needed for new production contracts).

---

## Test Results

37 tests passed, 0 failed (all 32 required spec tests + 5 supplementary).

Key tests:
- Tests 1–6: Revocation flag isolation (each actor can only clear their own)
- Test 7: `isValid()` returns false when any revocation flag active
- Tests 8–10: Recovery blocked on all revocation states
- Tests 11–12: Recovery wallet and recovery blocked after revocation/burn
- Test 13: Recovery preserves all credential fields
- Tests 14–17: Issuer deactivation/reactivation lifecycle
- Tests 18–19: Lapsed subscription vs. deactivated issuer distinction
- Tests 20–21: Membership/expiry consistency with revocation
- Tests 22–23: Quota cap enforcement
- Tests 24–26: 2-step registry update with delay and cancellation
- Tests 27–28: Soulbound enforcement (transfers and approvals revert)
- Tests 29–30: Registry linkage and marketplace soulbound safety
- Tests 31–32: Marketplace reentrancy protection and deactivated-issuer blocking

---

## Frontend Integration Notes

### New Contract Addresses
Replace all references to the beta contracts with the production addresses above.

### Changed Function Names / API

**VaultID (was VaultIDV4)**

| Change | Beta | Production |
|--------|------|------------|
| Revocation | `revoke(tokenId)` (single flag) | `revoke(tokenId)`, `revokeByIssuer(tokenId)`, `revokeByAdmin(tokenId)` |
| Unrevoke | `unrevoke(tokenId)` | `unrevoke(tokenId)`, `unrevokeByIssuer(tokenId)`, `unrevokeByAdmin(tokenId)` |
| Check validity | `revoked` (bool) | `isRevoked(tokenId)`, `isValid(tokenId)`, `revocationStatus(tokenId)` |
| Recovery | `setBackupWallet()` | `setRecoveryWallet()` only |
| Registry | instant swap | `proposeRegistry()` + `applyRegistryProposal()` |

**New events (VaultID):**
- `Revoked(tokenId, actor, flag)` — flag: 0=owner, 1=issuer, 2=admin
- `Unrevoked(tokenId, actor, flag)`
- `VaultRecovered(oldTokenId, newTokenId, newOwner)`
- `RecoveryWalletSet(tokenId, recoveryWallet)`
- `RegistryUpdateProposed(newRegistry, applyAt)`
- `RegistryUpdateCancelled(cancelled)`
- `RegistryUpdated(oldRegistry, newRegistry)`

**New events (Registry):**
- `SubscriptionPurchased(subscriber, tier, paidThrough)`
- `SubscriptionCancelled(subscriber)`
- `BasicMintConsumed(subscriber)`
- `VaultContractSet(vault)`

### Recommended Frontend Updates
1. Update `isValid()` display: show which actor revoked (owner/issuer/admin) for user clarity
2. Issuer management UI: use `issuerAdminRights()` to gate revoke/extend UI for issuers with lapsed subscriptions
3. Recovery flow: check `isRevoked()` before showing recovery option
4. Registry update: 2-step flow requires UX for proposing and confirming after 48h delay
5. Membership active: now derived — no need to flip `membership.active` manually

---

## Old Beta Contract Treatment

- `VaultIDV4` (0x491684F8E8FE944b0F55bC76678B9A107f394C9C) — remains deployed, read-only/historical
- `VaultIDRegistry` beta (0x917080A405e6BeC9b811A1617DDc7338D2EfA225) — remains deployed, historical
- `VaultIDMarketplace` beta (0x77974E0FA9EC4B2993e846A58C83b6EE75Bba2Ea) — remains deployed, historical

New minting should use the production VaultID contract. Frontend can show beta vaults as "legacy" with a migration notice.

---

## Security Properties Summary

- **Soulbound**: `transferFrom` and `safeTransferFrom` revert. `approve` and `setApprovalForAll` revert. Only mint, burn, and recovery change token ownership.
- **Reentrancy**: All payment/mint/recovery functions are `nonReentrant`.
- **Token safety**: SafeERC20 used for all USDC transfers.
- **Ownership**: Ownable2Step on all three contracts prevents accidental ownership transfer.
- **Revocation isolation**: Three independent flags prevent any single actor from overriding another.
- **Recovery safety**: Cannot launder a revoked credential; recovery preserves all data fields.
- **Issuer lifecycle**: Admin deactivation is permanent until admin re-enables; self-reactivation blocked.
- **Registry trust**: 48h delay on registry changes prevents instant malicious substitution.
