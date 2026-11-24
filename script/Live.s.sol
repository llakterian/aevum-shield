// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PayPolicy} from "../src/PayPolicy.sol";
import {InvoiceEscrow} from "../src/InvoiceEscrow.sol";
import {PaymentAgent} from "../src/PaymentAgent.sol";

/**
 * @title Live
 * @notice Runs the demonstration against the contracts already deployed on
 * Aevum Testnet.
 *
 * @dev The demonstration is deliberately built around the refusal. A video
 * of three payments going through proves very little; a payment being
 * refused *with the exact rule that refused it* proves the control plane
 * works.
 *
 * The flow is split into steps because one of them depends on the passage
 * of real time on a real chain:
 *
 *   step 1  create an invoice, pay it, then attempt one that is too large
 *           and show the policy's reason for refusing it
 *   step 2  settle the paid invoice (run after the dispute window)
 *   step 3  refund a paid invoice instead of settling it
 *
 * Configuration comes from the environment:
 *
 *   ESCROW, POLICY, AGENT   the deployed contract addresses
 *   MERCHANT_KEY            the key that owns the escrow
 *   TUSD8                   the token address
 *   PAYEE                   who receives the money on settlement
 *   AMOUNT_TUSD8            the invoice amount in whole tUSD8 (default: 25)
 *   BIG_AMOUNT_TUSD8        the over-cap invoice amount (default: 500)
 */
contract Live is Script {
    uint256 internal constant WHOLE = 1_000_000;

    InvoiceEscrow escrow;
    PayPolicy policy;
    PaymentAgent agent;
    address token;
    address payee;

    function run(uint256 step) external {
        uint256 merchantKey = vm.envUint("MERCHANT_KEY");
        token = vm.envAddress("TUSD8");
        payee = vm.envOr("PAYEE", vm.addr(merchantKey));

        escrow = InvoiceEscrow(vm.envAddress("ESCROW"));
        policy = PayPolicy(vm.envAddress("POLICY"));
        agent = PaymentAgent(vm.envAddress("AGENT"));

        if (step == 1) {
            _stepPayAndRefuse(merchantKey);
        } else if (step == 2) {
            _stepSettle(merchantKey);
        } else if (step == 3) {
            _stepRefund(merchantKey);
        } else {
            revert("unknown step");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                STEP 1
    //////////////////////////////////////////////////////////////*/

    function _stepPayAndRefuse(uint256 merchantKey) internal {
        uint256 amount = vm.envOr("AMOUNT_TUSD8", uint256(25)) * WHOLE;
        uint256 bigAmount = vm.envOr("BIG_AMOUNT_TUSD8", uint256(500)) * WHOLE;

        vm.startBroadcast(merchantKey);

        // --- The merchant writes an invoice. ---------------------------
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes32 invoiceId = escrow.createInvoice(payee, amount, deadline);
        console2.log("invoice      ");
        console2.logBytes32(invoiceId);
        console2.log("payee        ", payee);
        console2.log("amount       ", amount / WHOLE, "tUSD8");

        // --- The agent asks the policy first. -------------------------
        (bool allowed, string memory reason) = agent.canPay(address(escrow), invoiceId);
        console2.log("can pay?     ", allowed);
        console2.log("reason       ", reason);

        // --- The agent pays. -------------------------------------------
        bool paid = agent.pay(address(escrow), invoiceId);
        console2.log("paid         ", paid);
        console2.log("escrow holds ", IERC20(token).balanceOf(address(escrow)) / WHOLE, "tUSD8");

        // --- And now an invoice it must not pay. -----------------------
        bytes32 bigId = escrow.createInvoice(payee, bigAmount, deadline);
        (bool canBig,) = agent.canPay(address(escrow), bigId);
        bool bigPaid = agent.pay(address(escrow), bigId);
        console2.log("--- over the cap ---");
        console2.logBytes32(bigId);
        console2.log("amount       ", bigAmount / WHOLE, "tUSD8");
        console2.log("can pay?     ", canBig);
        console2.log("paid?        ", bigPaid);

        // The reason is read back from the policy rather than kept in a
        // local, so what is printed is what the contract actually said.
        (PayPolicy.Decision decision, string memory why) =
            policy.check(address(escrow), bigId, address(agent));
        console2.log("decision     ", uint8(decision));
        console2.log("reason       ", why);

        vm.stopBroadcast();
    }

    /*//////////////////////////////////////////////////////////////
                                STEP 2
    //////////////////////////////////////////////////////////////*/

    function _stepSettle(uint256 merchantKey) internal {
        bytes32 invoiceId = vm.envBytes32("INVOICE_ID");
        uint64 disputeUntil = escrow.disputeDeadline(invoiceId);
        console2.logBytes32(invoiceId);
        console2.log("dispute until", disputeUntil);
        console2.log("now          ", block.timestamp);

        if (block.timestamp <= disputeUntil) {
            console2.log("the dispute window is still open. Run this step again after it closes.");
            return;
        }

        vm.startBroadcast(merchantKey);
        escrow.settle(invoiceId);
        vm.stopBroadcast();

        console2.log("settled. payee now holds:", IERC20(token).balanceOf(payee) / WHOLE, "tUSD8");
    }

    /*//////////////////////////////////////////////////////////////
                                STEP 3
    //////////////////////////////////////////////////////////////*/

    function _stepRefund(uint256 merchantKey) internal {
        bytes32 invoiceId = vm.envBytes32("INVOICE_ID");

        vm.startBroadcast(merchantKey);
        policy.refund(address(escrow), invoiceId);
        vm.stopBroadcast();

        console2.log("refunded. escrow now holds:", IERC20(token).balanceOf(address(escrow)) / WHOLE, "tUSD8");
        console2.log("policy now holds:", IERC20(token).balanceOf(address(policy)) / WHOLE, "tUSD8");
    }
}
