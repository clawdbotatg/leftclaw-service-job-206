// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { console } from "forge-std/console.sol";
import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { VaultID } from "../contracts/VaultID.sol";
import { VaultIDRegistry } from "../contracts/VaultIDRegistry.sol";
import { VaultIDMarketplace } from "../contracts/VaultIDMarketplace.sol";

/**
 * @notice Deploys the VaultID system (Registry, VaultID, Marketplace) and links them.
 *
 * Deployment flow:
 *   1. Deploy VaultIDRegistry (deployer is initial owner).
 *   2. Deploy VaultID (deployer is initial owner).
 *   3. Deploy VaultIDMarketplace (deployer is initial owner).
 *   4. Link Registry -> VaultID (one-shot setVaultContract).
 *   5. Link VaultID -> Registry (proposeRegistry; bypasses 48h delay because registry==0).
 *   6. Apply registry proposal immediately (allowed for initial setup).
 *   7. Transfer ownership of all three contracts to the client wallet (Ownable2Step pending).
 *
 * After deployment, the client must call acceptOwnership() on each contract from their wallet.
 */
contract DeployVaultID is ScaffoldETHDeploy {
    // Base Mainnet USDC
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // CLAWD token is not yet deployed/known on Base. Pass address(0) — VaultID treats
    // address(0) as "CLAWD not configured" and any CLAWD-gated functionality reverts.
    address constant CLAWD = address(0);

    // Client wallet (will receive ownership of all contracts via Ownable2Step).
    address constant CLIENT_WALLET = 0xFE968dE21eb0E77d5877477C31a04A3075c0086E;

    function run() external ScaffoldEthDeployerRunner {
        address feeRecipient = CLIENT_WALLET;

        // 1. Deploy Registry
        VaultIDRegistry registry = new VaultIDRegistry(
            deployer,            // initial owner
            USDC,
            10e6,                // basicSubscriptionPrice: 10 USDC
            50e6,                // issuerSubscriptionPrice: 50 USDC
            30 days,             // subscriptionPeriod
            5                    // basicMintQuota per period
        );
        deployments.push(Deployment({ name: "VaultIDRegistry", addr: address(registry) }));

        // 2. Deploy VaultID
        VaultID vaultId = new VaultID(
            deployer,            // initial owner
            feeRecipient,
            USDC,
            CLAWD,
            0.001 ether,         // ethMintPrice
            5e6                  // usdcMintPrice: 5 USDC
        );
        deployments.push(Deployment({ name: "VaultID", addr: address(vaultId) }));

        // 3. Deploy Marketplace
        VaultIDMarketplace marketplace = new VaultIDMarketplace(
            deployer,            // initial owner
            USDC,
            address(registry),
            feeRecipient,
            250                  // 2.5% fee in basis points
        );
        deployments.push(Deployment({ name: "VaultIDMarketplace", addr: address(marketplace) }));

        // 4. Link Registry -> VaultID (single-shot wire).
        registry.setVaultContract(address(vaultId));

        // 5/6. Link VaultID -> Registry. Because registry was unset, the proposal can be applied
        // immediately, bypassing the 48h delay (only for initial setup).
        vaultId.proposeRegistry(address(registry));
        vaultId.applyRegistryProposal();

        // 7. Transfer ownership to the client wallet. Ownable2Step requires
        // the client to call acceptOwnership() on each contract.
        registry.transferOwnership(CLIENT_WALLET);
        vaultId.transferOwnership(CLIENT_WALLET);
        marketplace.transferOwnership(CLIENT_WALLET);

        console.log("VaultIDRegistry:    ", address(registry));
        console.log("VaultID:            ", address(vaultId));
        console.log("VaultIDMarketplace: ", address(marketplace));
        console.log("Pending owner:      ", CLIENT_WALLET);
        console.log("NOTE: Client must call acceptOwnership() on each contract.");
    }
}
