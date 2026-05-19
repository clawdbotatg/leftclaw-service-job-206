//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { DeployVaultID } from "./DeployVaultID.s.sol";

/**
 * @notice Main deployment script for all contracts
 * @dev Run this when you want to deploy multiple contracts at once
 *
 * Example: yarn deploy # runs this script(without`--file` flag)
 */
contract DeployScript is ScaffoldETHDeploy {
    function run() external {
        // Deploys VaultID system: Registry, VaultID, Marketplace
        DeployVaultID deployVaultID = new DeployVaultID();
        deployVaultID.run();
    }
}
