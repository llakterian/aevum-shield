// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PayPolicy} from "../src/PayPolicy.sol";
import {InvoiceEscrow} from "../src/InvoiceEscrow.sol";
import {PaymentAgent} from "../src/PaymentAgent.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

/**
 * @title Local
 * @notice Deploys the whole system to a local chain, with a mock stablecoin.
 *
 * @dev This is how the demonstration is developed and rehearsed. It runs
 * against anvil with a mock token that has tUSD8's six decimals, so the
 * local behaviour matches the testnet behaviour without needing a funded
 * wallet.
 *
 *   ./script/local-up.sh
 *
 * Three roles are kept apart on purpose, because the whole point of the
 * project is that they can be:
 *
 *   - the **payer**, which owns the policy and sets the rules;
 *   - the **merchant**, which owns the escrow and writes the invoices;
 *   - the **agent**, which is an operator and may ask the policy to pay.
 *
 * The agent's key is not the payer's key. That separation is what lets
 * the agent harness in `app/agent.mjs` try to change the rules and be
 * refused by the chain.
 */
contract Local is Script {
    using SafeERC20 for IERC20;

    uint256 internal constant WHOLE = 1_000_000;

    /// @dev A fixed deadline, not `block.timestamp + n`.
    ///
    /// `forge script` simulates and then broadcasts, and the two runs are
    /// at different timestamps. An invoice id is a hash of its terms, and
    /// the deadline is one of them, so a relative deadline makes the
    /// simulated id and the on-chain id disagree. A fixed deadline makes
    /// them agree.
    uint64 internal constant DEMO_DEADLINE = 1_893_456_000; // 2030-01-01Z

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 merchantKey = vm.envUint("MERCHANT_PRIVATE_KEY");
        uint256 agentKey = vm.envUint("AGENT_PRIVATE_KEY");

        address deployer = vm.addr(deployerKey);
        address merchant = vm.addr(merchantKey);
        address agentOperator = vm.addr(agentKey);

        // --- The payer deploys and configures the policy. --------------
        vm.startBroadcast(deployerKey);

        // A mock with the same shape as tUSD8: six decimals, not eighteen.
        MockToken token = new MockToken("tUSD8", "tUSD8", 6);

        InvoiceEscrow escrow = new InvoiceEscrow(address(token), merchant);
        PayPolicy policy = new PayPolicy(address(token), deployer);
        PaymentAgent agent = new PaymentAgent(address(policy));

        policy.setEscrow(address(escrow), true);

        // Two operators. The contract is the automatic executor; the
        // external key is the AI agent, which is the thing this project is
        // actually about. Both have their own daily cap.
        policy.setOperator(address(agent), true);
        policy.setOperatorCap(address(agent), 30 * WHOLE);
        policy.setOperator(agentOperator, true);
        policy.setOperatorCap(agentOperator, 30 * WHOLE);

        policy.setCaps(50 * WHOLE, 50 * WHOLE, 50 * WHOLE);

        token.mint(deployer, 1_000_000 * WHOLE);
        IERC20(address(token)).safeTransfer(address(policy), 100 * WHOLE);

        // One payee on the allowlist, one deliberately left off it.
        policy.setPayee(vm.addr(0xDECAF), true);

        vm.stopBroadcast();

        // --- The merchant writes the invoices. --------------------------
        vm.startBroadcast(merchantKey);

        escrow.setDisputeWindow(60);

        // Three invoices, so the demo has three different outcomes to
        // show: one that goes through, one refused for being over the
        // cap, and one refused because the payee is not on the allowlist.
        bytes32 payable_ = escrow.createInvoice(vm.addr(0xDECAF), 25 * WHOLE, DEMO_DEADLINE);
        bytes32 overCap = escrow.createInvoice(vm.addr(0xDECAF), 500 * WHOLE, DEMO_DEADLINE);
        bytes32 unknownPayee = escrow.createInvoice(vm.addr(0xBEEF), 25 * WHOLE, DEMO_DEADLINE);

        vm.stopBroadcast();

        console2.log("=== Aevum Shield (local) ===");
        console2.log("TUSD8        ", address(token));
        console2.log("ESCROW       ", address(escrow));
        console2.log("POLICY       ", address(policy));
        console2.log("AGENT        ", address(agent));
        console2.log("PAYER        ", deployer);
        console2.log("MERCHANT     ", merchant);
        console2.log("AGENT OPERATOR", agentOperator);
        console2.log("PAYEE        ", vm.addr(0xDECAF));
        console2.log("--- invoices ---");
        console2.log("payable      ");
        console2.logBytes32(payable_);
        console2.log("over cap     ");
        console2.logBytes32(overCap);
        console2.log("unknown payee");
        console2.logBytes32(unknownPayee);
    }
}
