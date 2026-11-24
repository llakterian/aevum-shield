// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PayPolicy} from "../src/PayPolicy.sol";
import {InvoiceEscrow} from "../src/InvoiceEscrow.sol";
import {PaymentAgent} from "../src/PaymentAgent.sol";

/**
 * @title Deploy
 * @notice Deploys Aevum Shield to Aevum Testnet and wires it up.
 *
 * @dev The three contracts are owned by three different people on purpose:
 *
 *   - the **merchant** owns the escrow, so it is the merchant who can
 *     create invoices and release money;
 *   - the **payer** owns the policy, so it is the payer who sets the
 *     allowlist and the caps;
 *   - the **agent** owns nothing at all.
 *
 * A deployment where one address controls everything would not be a
 * control plane, it would be a suggestion.
 *
 * Each role's configuration is sent by that role's own key, because every
 * one of those calls is owner-gated. When a role's key is not available
 * the script says so rather than silently skipping the setup.
 *
 * Configuration comes from the environment, with sensible defaults so a
 * clean checkout can deploy in one command:
 *
 *   DEPLOYER_PRIVATE_KEY  the key that pays for the deployment
 *   TUSD8                 0x456569838f1d43009A91ebA4263147Afd7233483
 *   PAYER_KEY             the payer's key   (default: the deployer)
 *   MERCHANT_KEY          the merchant's key (default: the deployer)
 *   AGENT_KEY             the agent's key    (default: the deployer)
 *   PAYEE                 the payee's address (default: the deployer)
 *   DAILY_CAP_TUSD8       the payer's daily cap in whole tUSD8 (default: 50)
 *   AGENT_CAP_TUSD8       the agent's own daily cap in whole tUSD8 (default: 30)
 *   DISPUTE_WINDOW        seconds before a merchant may settle (default: 60)
 *   FUNDING_TUSD8         how much tUSD8 to move into the policy (default: 100)
 */
contract Deploy is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant WHOLE = 1_000_000; // tUSD8 has 6 decimals

    /// @dev Everything the deployment needs, read once.
    ///
    /// It is a struct rather than a pile of locals because the compiler
    /// runs out of stack slots otherwise, and the alternative — dropping
    /// the separate roles to save a stack slot — would give up the one
    /// property the deployment exists to show.
    struct Config {
        uint256 deployerKey;
        uint256 payerKey;
        uint256 merchantKey;
        uint256 agentKey;
        address token;
        address payee;
        uint256 dailyCapWhole;
        uint256 agentCapWhole;
        uint64 disputeWindow;
        uint256 fundingWhole;
    }

    struct Deployment {
        address escrow;
        address policy;
        address agent;
        address token;
        address payer;
        address merchant;
        address payee;
    }

    Deployment public deployment;

    function run() external {
        Config memory c = _readConfig();
        _deployContracts(c);
        _configureEscrow(c);
        _configurePolicy(c);
        _fundPolicy(c);
        _report(c);
    }

    /// @dev Read the configuration out of the environment.
    function _readConfig() private view returns (Config memory c) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        c.deployerKey = deployerKey;
        c.payerKey = vm.envOr("PAYER_KEY", deployerKey);
        c.merchantKey = vm.envOr("MERCHANT_KEY", deployerKey);
        c.agentKey = vm.envOr("AGENT_KEY", deployerKey);
        c.token = vm.envOr("TUSD8", address(0x456569838f1d43009A91ebA4263147Afd7233483));
        c.payee = vm.envOr("PAYEE", vm.addr(deployerKey));
        c.dailyCapWhole = vm.envOr("DAILY_CAP_TUSD8", uint256(50));
        c.agentCapWhole = vm.envOr("AGENT_CAP_TUSD8", uint256(30));
        c.disputeWindow = uint64(vm.envOr("DISPUTE_WINDOW", uint256(60)));
        c.fundingWhole = vm.envOr("FUNDING_TUSD8", uint256(100));

        require(c.token != address(0), "TUSD8 address is not set");
    }

    /// @dev Put the three contracts on chain. The deployer pays for them.
    function _deployContracts(Config memory c) private {
        vm.startBroadcast(c.deployerKey);

        // The merchant owns the escrow. The payer owns the policy.
        deployment.escrow = address(new InvoiceEscrow(c.token, vm.addr(c.merchantKey)));
        deployment.policy = address(new PayPolicy(c.token, vm.addr(c.payerKey)));
        deployment.agent = address(new PaymentAgent(deployment.policy));

        vm.stopBroadcast();
    }

    /// @dev The merchant sets the dispute window. It is owner-gated on the
    /// escrow, so the merchant's key has to send it.
    function _configureEscrow(Config memory c) private {
        vm.startBroadcast(c.merchantKey);
        InvoiceEscrow(deployment.escrow).setDisputeWindow(c.disputeWindow);
        vm.stopBroadcast();
    }

    /// @dev The payer writes the rules. Every one of these is owner-gated
    /// on the policy, so the payer's key has to send them.
    function _configurePolicy(Config memory c) private {
        PayPolicy policy = PayPolicy(deployment.policy);

        vm.startBroadcast(c.payerKey);
        policy.setEscrow(deployment.escrow, true);
        policy.setPayee(c.payee, true);

        // Two operators. The contract is the automatic executor; the
        // external key is the AI agent, which is the thing this project is
        // actually about. Both have their own daily cap.
        policy.setOperator(deployment.agent, true);
        policy.setOperatorCap(deployment.agent, c.agentCapWhole * WHOLE);
        policy.setOperator(vm.addr(c.agentKey), true);
        policy.setOperatorCap(vm.addr(c.agentKey), c.agentCapWhole * WHOLE);

        policy.setCaps(c.dailyCapWhole * WHOLE, c.dailyCapWhole * WHOLE, c.dailyCapWhole * WHOLE);
        vm.stopBroadcast();
    }

    /// @dev Put the money in the policy. The policy is what holds the
    /// payer's funds; an escrow never touches the payer's wallet.
    function _fundPolicy(Config memory c) private {
        vm.startBroadcast(c.deployerKey);
        IERC20(c.token).safeTransfer(deployment.policy, c.fundingWhole * WHOLE);
        vm.stopBroadcast();
    }

    /// @dev Print what was deployed, for the run log and the README.
    function _report(Config memory c) private {
        deployment.token = c.token;
        deployment.payer = vm.addr(c.payerKey);
        deployment.merchant = vm.addr(c.merchantKey);
        deployment.payee = c.payee;

        console2.log("=== Aevum Shield deployed ===");
        console2.log("tUSD8        ", deployment.token);
        console2.log("InvoiceEscrow", deployment.escrow);
        console2.log("PayPolicy    ", deployment.policy);
        console2.log("PaymentAgent ", deployment.agent);
        console2.log("payer        ", deployment.payer);
        console2.log("merchant     ", deployment.merchant);
        console2.log("agent key    ", vm.addr(c.agentKey));
        console2.log("payee        ", deployment.payee);
        console2.log("daily cap    ", c.dailyCapWhole);
        console2.log("agent cap    ", c.agentCapWhole);
        console2.log("dispute secs ", c.disputeWindow);
        console2.log("funded       ", c.fundingWhole * WHOLE);
    }
}
