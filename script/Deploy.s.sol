// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
 * Configuration comes from the environment, with sensible defaults so a
 * clean checkout can deploy in one command:
 *
 *   DEPLOYER_PRIVATE_KEY  the key that pays for the deployment
 *   TUSD8                 0x456569838f1d43009A91ebA4263147Afd7233483
 *   PAYER                 the payer's address  (default: the deployer)
 *   MERCHANT              the merchant's address (default: the deployer)
 *   PAYEE                 the payee's address   (default: the deployer)
 *   DAILY_CAP_TUSD8       the payer's daily cap in whole tUSD8 (default: 50)
 *   AGENT_CAP_TUSD8       the agent's own daily cap in whole tUSD8 (default: 20)
 *   DISPUTE_WINDOW        seconds before a merchant may settle (default: 60)
 *   FUNDING_TUSD8         how much tUSD8 to move into the policy (default: 100)
 */
contract Deploy is Script {
    uint256 internal constant WHOLE = 1_000_000; // tUSD8 has 6 decimals

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
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address token = vm.envOr("TUSD8", address(0x456569838f1d43009A91ebA4263147Afd7233483));
        address payer = vm.envOr("PAYER", deployer);
        address merchant = vm.envOr("MERCHANT", deployer);
        address payee = vm.envOr("PAYEE", deployer);
        uint256 dailyCapWhole = vm.envOr("DAILY_CAP_TUSD8", uint256(50));
        uint256 agentCapWhole = vm.envOr("AGENT_CAP_TUSD8", uint256(20));
        uint64 disputeWindow = uint64(vm.envOr("DISPUTE_WINDOW", uint256(60)));
        uint256 fundingWhole = vm.envOr("FUNDING_TUSD8", uint256(100));

        require(token != address(0), "TUSD8 address is not set");

        vm.startBroadcast(deployerKey);

        // The merchant owns the escrow. The payer owns the policy.
        InvoiceEscrow escrow = new InvoiceEscrow(token, merchant);
        PayPolicy policy = new PayPolicy(token, payer);
        PaymentAgent agent = new PaymentAgent(address(policy));

        escrow.setDisputeWindow(disputeWindow);

        // The payer's rules. These are owner calls, so they only work when
        // the payer is the broadcaster.
        if (payer == deployer) {
            policy.setEscrow(address(escrow), true);
            policy.setPayee(payee, true);
            policy.setOperator(address(agent), true);
            policy.setOperatorCap(address(agent), agentCapWhole * WHOLE);
            policy.setCaps(
                dailyCapWhole * WHOLE, dailyCapWhole * WHOLE, dailyCapWhole * WHOLE
            );
        }

        // Put the money in the policy. The policy is what holds the payer's
        // funds; an escrow never touches the payer's wallet.
        uint256 funding = fundingWhole * WHOLE;
        require(IERC20(token).transfer(address(policy), funding), "funding transfer failed");

        vm.stopBroadcast();

        deployment = Deployment({
            escrow: address(escrow),
            policy: address(policy),
            agent: address(agent),
            token: token,
            payer: payer,
            merchant: merchant,
            payee: payee
        });

        console2.log("=== Aevum Shield deployed ===");
        console2.log("tUSD8        ", token);
        console2.log("InvoiceEscrow", address(escrow));
        console2.log("PayPolicy    ", address(policy));
        console2.log("PaymentAgent ", address(agent));
        console2.log("payer        ", payer);
        console2.log("merchant     ", merchant);
        console2.log("payee        ", payee);
        console2.log("daily cap    ", dailyCapWhole);
        console2.log("agent cap    ", agentCapWhole);
        console2.log("dispute secs ", disputeWindow);
        console2.log("funded       ", funding);
    }
}
