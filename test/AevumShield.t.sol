// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {PayPolicy} from "../src/PayPolicy.sol";
import {InvoiceEscrow} from "../src/InvoiceEscrow.sol";
import {PaymentAgent} from "../src/PaymentAgent.sol";

/**
 * @title AevumShieldTest
 * @notice The control plane's rules, and the payment flow they govern.
 *
 * @dev The tests are the argument that this product is safe. Every rule the
 * policy advertises has a test that proves it is enforced, and every way a
 * payment flow can be short-changed has a test that proves it is not.
 *
 * The token uses 6 decimals, like tUSD8. Amounts here are in raw units, so
 * "10 tUSD8" is 10_000_000.
 */
contract AevumShieldTest is Test {
    MockToken token;
    PayPolicy policy;
    InvoiceEscrow escrow;
    PaymentAgent agent;

    address payer = address(0xA11CE);
    address operator = address(0xB0B); // the AI agent's own key
    address merchant = address(0xC0FFEE);
    address payee = address(0xDECAF);
    address otherPayee = address(0xBEEF);
    address stranger = address(0xBAD);

    uint256 constant UNIT = 1e6; // one tUSD8
    uint256 constant CAP = 50 * UNIT;

    function setUp() public {
        // A realistic timestamp, so deadlines and UTC day boundaries behave
        // the way they will on Aevum rather than at the epoch.
        vm.warp(1_700_000_000);

        token = new MockToken("tUSD8", "tUSD8", 6);
        policy = new PayPolicy(address(token), payer);
        escrow = new InvoiceEscrow(address(token), merchant);
        agent = new PaymentAgent(address(policy));

        // The payer's rules. Every one of these is an owner-only call, so
        // they have to come from the payer.
        vm.startPrank(payer);
        policy.setPayee(payee, true);
        policy.setEscrow(address(escrow), true);
        policy.setOperator(operator, true);
        policy.setOperator(address(agent), true);
        policy.setCaps(CAP, CAP, CAP);
        vm.stopPrank();

        // Money in.
        token.mint(payer, 1_000_000 * UNIT);
        vm.prank(payer);
        assertTrue(token.transfer(address(policy), 1_000_000 * UNIT));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _invoice(uint256 amount, uint64 deadline) internal returns (bytes32 id) {
        vm.prank(merchant);
        id = escrow.createInvoice(payee, amount, deadline);
    }

    function _invoiceFor(address to, uint256 amount, uint64 deadline)
        internal
        returns (bytes32 id)
    {
        vm.prank(merchant);
        id = escrow.createInvoice(to, amount, deadline);
    }

    function _approve(bytes32 id) internal {
        vm.prank(operator);
        policy.approve(address(escrow), id);
    }

    function _check(bytes32 id) internal view returns (PayPolicy.Decision decision, string memory why) {
        return policy.check(address(escrow), id, operator);
    }

    /*//////////////////////////////////////////////////////////////
                            THE POLICY RULES
    //////////////////////////////////////////////////////////////*/

    function test_DeniesByDefaultWhenNoPayeeIsAllowed() public {
        // A fresh policy trusts nobody and allows nobody.
        PayPolicy blank = new PayPolicy(address(token), payer);
        bytes32 id = _invoice(10 * UNIT, 0);

        (PayPolicy.Decision decision, string memory reason) =
            blank.check(address(escrow), id, operator);

        assertEq(uint8(decision), uint8(PayPolicy.Decision.EscrowNotTrusted));
        assertTrue(bytes(reason).length > 0);
    }

    function test_RefusesAPayeeThatIsNotAllowed() public {
        // `payee` is on the allowlist; `otherPayee` is not.
        bytes32 id = _invoiceFor(otherPayee, 10 * UNIT, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.PayeeNotAllowed,
                "that payee is not on the allowed list"
            )
        );
        vm.prank(operator);
        policy.approve(address(escrow), id);
    }

    function test_AllowsAPayeeThatWasAddedToTheList() public {
        bytes32 id = _invoiceFor(otherPayee, 10 * UNIT, 0);

        (PayPolicy.Decision decision,) = _check(id);
        assertEq(uint8(decision), uint8(PayPolicy.Decision.PayeeNotAllowed));

        vm.prank(payer);
        policy.setPayee(otherPayee, true);

        (decision,) = _check(id);
        assertEq(uint8(decision), uint8(PayPolicy.Decision.Allowed));
    }

    function test_RefusesWhenPaused() public {
        bytes32 id = _invoice(10 * UNIT, 0);
        vm.prank(payer);
        policy.setPaused(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.Paused,
                "payments are paused"
            )
        );
        vm.prank(operator);
        policy.approve(address(escrow), id);
    }

    function test_APauseDoesNotTrapFunds() public {
        bytes32 id = _invoice(10 * UNIT, 0);
        _approve(id);

        vm.prank(payer);
        policy.setPaused(true);

        // The reservation can still be released and the money recovered.
        vm.warp(block.timestamp + 2 hours);
        policy.releaseExpired();
        assertEq(policy.dailySpent(), 0);

        uint256 before = token.balanceOf(payer);
        vm.prank(payer);
        policy.recover(address(token), payer, 10 * UNIT);
        assertEq(token.balanceOf(payer), before + 10 * UNIT);
    }

    function test_RefusesAnUntrustedEscrow() public {
        InvoiceEscrow rogue = new InvoiceEscrow(address(token), stranger);
        bytes32 id = _invoice(10 * UNIT, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.EscrowNotTrusted,
                "that escrow is not on the trusted list"
            )
        );
        vm.prank(operator);
        policy.approve(address(rogue), id);
    }

    function test_RefusesAnUnknownInvoice() public view {
        bytes32 id = keccak256("nothing here");

        (PayPolicy.Decision decision, string memory reason) = _check(id);
        assertEq(uint8(decision), uint8(PayPolicy.Decision.InvoiceUnknown));
        assertEq(reason, "that invoice does not exist");
    }

    function test_RefusesAboveTheSinglePaymentCap() public {
        bytes32 id = _invoice(CAP + 1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.PerPaymentCapExceeded,
                "the amount is above the single-payment cap"
            )
        );
        vm.prank(operator);
        policy.approve(address(escrow), id);
    }

    function test_RefusesAboveThePerPayeeCap() public {
        // The per-payee cap is a daily total to one payee, not a repeat of
        // the single-payment cap. Two payments of 30 to the same payee must
        // trip a 50 cap even though each one is under it.
        bytes32 first = _invoice(30 * UNIT, 0);
        _approve(first);

        bytes32 second = _invoice(30 * UNIT, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.PerPayeeCapExceeded,
                "the amount is above the cap for that payee today"
            )
        );
        vm.prank(operator);
        policy.approve(address(escrow), second);
    }

    function test_ThePerPayeeCapIsPerPayee() public {
        // Raise the daily cap so the per-payee cap is the only one that bites.
        vm.prank(payer);
        policy.setCaps(CAP, CAP, 100 * UNIT);

        bytes32 first = _invoice(30 * UNIT, 0);
        _approve(first);

        // A different payee has its own budget.
        bytes32 second = _invoiceFor(otherPayee, 30 * UNIT, 0);
        vm.prank(payer);
        policy.setPayee(otherPayee, true);

        vm.prank(operator);
        policy.approve(address(escrow), second);
        assertEq(policy.perPayeeSpent(payee), 30 * UNIT);
        assertEq(policy.perPayeeSpent(otherPayee), 30 * UNIT);
    }

    function test_ThePerPayeeCapResetsAfterADay() public {
        bytes32 first = _invoice(CAP, 0);
        _approve(first);
        assertEq(policy.perPayeeSpent(payee), CAP);

        vm.warp(block.timestamp + 1 days);
        bytes32 second = _invoice(CAP, 0);
        vm.prank(operator);
        policy.approve(address(escrow), second);
        assertEq(policy.perPayeeSpent(payee), CAP);
    }

    function test_RefusesAboveTheDailyCap() public {
        // Two payments of 30 each: the first passes, the second does not,
        // because the cap is 50.
        bytes32 first = _invoice(30 * UNIT, 0);
        _approve(first);

        bytes32 second = _invoiceFor(otherPayee, 30 * UNIT, 0);
        vm.prank(payer);
        policy.setPayee(otherPayee, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.DailyCapExceeded,
                "the amount is above the daily cap"
            )
        );
        vm.prank(operator);
        policy.approve(address(escrow), second);
    }

    function test_TheDailyCapResetsAfterADay() public {
        bytes32 first = _invoice(CAP, 0);
        _approve(first);

        // A second payee, so the per-payee cap is not what stops this.
        bytes32 second = _invoiceFor(otherPayee, 30 * UNIT, 0);
        vm.prank(payer);
        policy.setPayee(otherPayee, true);

        // Still capped today.
        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.DailyCapExceeded,
                "the amount is above the daily cap"
            )
        );
        vm.prank(operator);
        policy.approve(address(escrow), second);

        // Tomorrow it is fine.
        vm.warp(block.timestamp + 1 days);
        vm.prank(operator);
        policy.approve(address(escrow), second);
        assertEq(policy.dailySpent(), 30 * UNIT);
    }

    function test_AnOperatorCannotExceedItsOwnCap() public {
        // The agent gets a smaller budget than the payer has.
        vm.prank(payer);
        policy.setOperatorCap(operator, 10 * UNIT);

        bytes32 first = _invoice(10 * UNIT, 0);
        _approve(first);

        bytes32 second = _invoice(1 * UNIT, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.OperatorCapExceeded,
                "the amount is above the operator's own daily cap"
            )
        );
        vm.prank(operator);
        policy.approve(address(escrow), second);
    }

    function test_TheOperatorCapIsCheckedAgainstTheAskingOperator() public {
        vm.prank(payer);
        policy.setOperatorCap(operator, 1 * UNIT);

        bytes32 id = _invoice(10 * UNIT, 0);

        // The operator is over its own cap.
        (PayPolicy.Decision decision,) = policy.check(address(escrow), id, operator);
        assertEq(uint8(decision), uint8(PayPolicy.Decision.OperatorCapExceeded));

        // The owner has no operator cap of its own.
        (decision,) = policy.check(address(escrow), id, payer);
        assertEq(uint8(decision), uint8(PayPolicy.Decision.Allowed));
    }

    function test_TheOwnerIsAlsoAnOperator() public {
        bytes32 id = _invoice(1 * UNIT, 0);
        vm.prank(payer);
        policy.approve(address(escrow), id);
        assertTrue(policy.invoiceApproved(id));
    }

    function test_AStrangerCannotApproveAnything() public {
        bytes32 id = _invoice(1 * UNIT, 0);
        vm.expectRevert(PayPolicy.NotOperator.selector);
        vm.prank(stranger);
        policy.approve(address(escrow), id);
    }

    function test_RefusesAnExpiredInvoice() public {
        bytes32 id = _invoice(1 * UNIT, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.InvoiceExpired,
                "that invoice has expired"
            )
        );
        vm.prank(operator);
        policy.approve(address(escrow), id);
    }

    function test_RefusesToApproveTheSameInvoiceTwice() public {
        bytes32 id = _invoice(1 * UNIT, 0);
        _approve(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                PayPolicy.PolicyDenied.selector,
                PayPolicy.Decision.AlreadyApproved,
                "that invoice has already been approved"
            )
        );
        vm.prank(operator);
        policy.approve(address(escrow), id);
    }

    function test_RefusesAnInvoiceThatHasAlreadyBeenPaid() public {
        bytes32 id = _invoice(1 * UNIT, 0);
        _approve(id);
        escrow.pay(id, address(policy));

        (PayPolicy.Decision decision, string memory reason) = _check(id);
        assertEq(uint8(decision), uint8(PayPolicy.Decision.InvoiceAlreadyPaid));
        assertEq(reason, "that invoice has already been paid");
    }

    /*//////////////////////////////////////////////////////////////
                        RESERVATIONS AND BUDGET
    //////////////////////////////////////////////////////////////*/

    function test_TheBudgetIsReservedAtApprovalNotAtSettlement() public {
        bytes32 id = _invoice(30 * UNIT, 0);
        _approve(id);

        // The escrow has not been paid yet, but the money is already spoken
        // for. A second approval cannot slip past the cap.
        assertEq(policy.dailySpent(), 30 * UNIT);
        assertEq(policy.totalReserved(), 30 * UNIT);
    }

    function test_AnUnusedReservationExpiresAndReturnsTheBudget() public {
        bytes32 id = _invoice(30 * UNIT, 0);
        _approve(id);
        assertEq(policy.dailySpent(), 30 * UNIT);

        vm.warp(block.timestamp + 2 hours);
        policy.releaseExpired();

        assertEq(policy.dailySpent(), 0);
        assertEq(policy.totalReserved(), 0);
        assertFalse(policy.invoiceApproved(id));
    }

    function test_AReservationCannotBeReleasedBeforeItExpires() public {
        bytes32 id = _invoice(1 * UNIT, 0);
        _approve(id);

        vm.expectRevert(abi.encodeWithSelector(PayPolicy.ReservationExpired.selector, id));
        vm.prank(payer);
        policy.release(id);
    }

    function test_OnlyTheOwnerOrTheOperatorCanRelease() public {
        bytes32 id = _invoice(1 * UNIT, 0);
        _approve(id);
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(PayPolicy.NotOperator.selector);
        vm.prank(stranger);
        policy.release(id);
    }

    function test_ReleasingAfterTheDayRollsDoesNotCorruptTodaysBudget() public {
        bytes32 id = _invoice(30 * UNIT, 0);
        _approve(id);

        // The reservation expires two days later, by which time yesterday's
        // spend has already been cleared. Handing it back must not subtract
        // from today's spend.
        vm.warp(block.timestamp + 2 days);
        policy.releaseExpired();
        assertEq(policy.dailySpent(), 0);

        // Today's budget is intact.
        bytes32 today = _invoice(30 * UNIT, 0);
        _approve(today);
        assertEq(policy.dailySpent(), 30 * UNIT);
    }

    function test_TheOwnerCanRecoverUnreservedFunds() public {
        // Money that is not reserved can be swept.
        uint256 before = token.balanceOf(payer);
        vm.prank(payer);
        policy.recover(address(token), payer, 100 * UNIT);
        assertEq(token.balanceOf(payer), before + 100 * UNIT);
    }

    function test_ReservedFundsCannotBeRecovered() public {
        bytes32 id = _invoice(30 * UNIT, 0);
        _approve(id);

        uint256 reserved = policy.totalReserved();
        assertEq(reserved, 30 * UNIT);

        // Sweeping the whole balance would take the reserved money with it.
        uint256 balance = token.balanceOf(address(policy));
        vm.expectRevert(abi.encodeWithSelector(PayPolicy.NothingToRecover.selector, address(token)));
        vm.prank(payer);
        policy.recover(address(token), payer, balance);
    }

    function test_RecoverStopsExactlyAtTheReservedAmount() public {
        bytes32 id = _invoice(30 * UNIT, 0);
        _approve(id);

        uint256 reserved = policy.totalReserved();
        uint256 balance = token.balanceOf(address(policy));

        // Everything except the reservation is sweepable.
        vm.prank(payer);
        policy.recover(address(token), payer, balance - reserved);
        assertEq(token.balanceOf(address(policy)), reserved);

        // One unit more is refused.
        vm.expectRevert(abi.encodeWithSelector(PayPolicy.NothingToRecover.selector, address(token)));
        vm.prank(payer);
        policy.recover(address(token), payer, 1);
    }

    function test_ConsumedFundsAreNoLongerReserved() public {
        bytes32 id = _invoice(30 * UNIT, 0);
        _approve(id);
        escrow.pay(id, address(policy));

        // The money has left the policy contract. It must not still count as
        // reserved, or `recover` would underflow.
        assertEq(policy.totalReserved(), 0);
        assertEq(policy.dailySpent(), 30 * UNIT);

        uint256 before = token.balanceOf(payer);
        vm.prank(payer);
        policy.recover(address(token), payer, 1 * UNIT);
        assertEq(token.balanceOf(payer), before + 1 * UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                            THE PAYMENT FLOW
    //////////////////////////////////////////////////////////////*/

    function test_TheFullHappyPath() public {
        bytes32 id = _invoice(25 * UNIT, uint64(block.timestamp + 1 days));

        _approve(id);

        // The escrow pulls exactly what was authorised.
        escrow.pay(id, address(policy));
        assertEq(token.balanceOf(address(escrow)), 25 * UNIT);
        assertEq(uint8(escrow.statusOf(id)), uint8(InvoiceEscrow.Status.Paid));

        // The merchant cannot settle during the dispute window.
        vm.expectRevert(abi.encodeWithSelector(InvoiceEscrow.DisputeWindowOpen.selector, id));
        vm.prank(merchant);
        escrow.settle(id);

        // After it, the payee is paid.
        vm.warp(block.timestamp + 25 hours);
        vm.prank(merchant);
        escrow.settle(id);

        assertEq(token.balanceOf(payee), 25 * UNIT);
        assertEq(uint8(escrow.statusOf(id)), uint8(InvoiceEscrow.Status.Settled));
    }

    function test_TheDisputeWindowStartsWhenThePaymentArrives() public {
        // An invoice written days ago still gets a full dispute window
        // after it is paid. Otherwise a merchant could create an invoice
        // early and settle it the moment the money lands.
        bytes32 id = _invoice(5 * UNIT, 0);
        vm.warp(block.timestamp + 5 days);

        _approve(id);
        escrow.pay(id, address(policy));

        assertEq(escrow.disputeDeadline(id), block.timestamp + 24 hours);

        vm.expectRevert(abi.encodeWithSelector(InvoiceEscrow.DisputeWindowOpen.selector, id));
        vm.prank(merchant);
        escrow.settle(id);
    }

    function test_TwoInvoicesForTheSameEscrowCanBothBePaid() public {
        // An ERC-20 allowance is keyed by (owner, spender), so approving a
        // second invoice for the same merchant would have cancelled the
        // first one's authorisation. Each reservation has to stand alone.
        bytes32 first = _invoice(10 * UNIT, 0);
        bytes32 second = _invoice(10 * UNIT, 0);

        _approve(first);
        _approve(second);

        escrow.pay(first, address(policy));
        escrow.pay(second, address(policy));

        assertEq(token.balanceOf(address(escrow)), 20 * UNIT);
        assertEq(policy.totalReserved(), 0);
    }

    function test_TheEscrowPullsExactlyWhatWasApproved() public {
        bytes32 id = _invoice(25 * UNIT, 0);
        _approve(id);

        escrow.pay(id, address(policy));

        // The reservation is spent. Pulling again cannot move more money.
        vm.expectRevert(
            abi.encodeWithSelector(PayPolicy.ReservationNotPending.selector, id)
        );
        policy.pull(id, address(escrow));
    }

    function test_AnEscrowCannotPullAnotherEscrowsReservation() public {
        InvoiceEscrow rogue = new InvoiceEscrow(address(token), stranger);
        bytes32 id = _invoice(5 * UNIT, 0);
        _approve(id);

        vm.expectRevert(abi.encodeWithSelector(PayPolicy.NotTrustedEscrow.selector, address(rogue)));
        policy.pull(id, address(rogue));
    }

    function test_AnInvoiceCannotBePaidTwice() public {
        bytes32 id = _invoice(5 * UNIT, 0);
        _approve(id);
        escrow.pay(id, address(policy));

        vm.expectRevert(abi.encodeWithSelector(InvoiceEscrow.InvoiceAlreadyPaid.selector, id));
        escrow.pay(id, address(policy));
    }

    function test_AnUnapprovedInvoiceCannotBePaid() public {
        bytes32 id = _invoice(5 * UNIT, 0);

        vm.expectRevert();
        escrow.pay(id, address(policy));
    }

    function test_AnExpiredInvoiceCannotBePaid() public {
        bytes32 id = _invoice(5 * UNIT, uint64(block.timestamp + 1 hours));
        _approve(id);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(InvoiceEscrow.InvoiceExpired.selector, id));
        escrow.pay(id, address(policy));
    }

    function test_ThePayerCanRefundThroughThePolicy() public {
        bytes32 id = _invoice(5 * UNIT, 0);
        _approve(id);
        escrow.pay(id, address(policy));

        uint256 before = token.balanceOf(address(policy));
        vm.prank(payer);
        policy.refund(address(escrow), id);

        assertEq(token.balanceOf(address(policy)), before + 5 * UNIT);
        assertEq(uint8(escrow.statusOf(id)), uint8(InvoiceEscrow.Status.Refunded));
    }

    function test_ARefundDoesNotHandBackTheBudget() public {
        bytes32 id = _invoice(5 * UNIT, 0);
        _approve(id);
        escrow.pay(id, address(policy));

        vm.prank(payer);
        policy.refund(address(escrow), id);

        // The money came back, but the budget did not. A refund must not be
        // a way for the agent to spend the same allowance twice.
        assertEq(policy.dailySpent(), 5 * UNIT);
    }

    function test_AStrangerCannotRefund() public {
        bytes32 id = _invoice(5 * UNIT, 0);
        _approve(id);
        escrow.pay(id, address(policy));

        vm.expectRevert(PayPolicy.NotOperator.selector);
        vm.prank(stranger);
        policy.refund(address(escrow), id);
    }

    function test_AMerchantCannotRefund() public {
        bytes32 id = _invoice(5 * UNIT, 0);
        _approve(id);
        escrow.pay(id, address(policy));

        vm.expectRevert(PayPolicy.NotOperator.selector);
        vm.prank(merchant);
        policy.refund(address(escrow), id);
    }

    function test_AMerchantCannotCreateAnInvoiceForSomebodyElse() public {
        vm.expectRevert();
        vm.prank(stranger);
        escrow.createInvoice(payee, 1 * UNIT, 0);
    }

    function test_InvoiceIdsAreUnique() public {
        bytes32 first = _invoice(1 * UNIT, 0);
        bytes32 second = _invoice(1 * UNIT, 0);
        assertTrue(first != second);
    }

    function test_AnExpiredInvoiceCannotBeCreated() public {
        vm.expectRevert(InvoiceEscrow.DeadlineInThePast.selector);
        vm.prank(merchant);
        escrow.createInvoice(payee, 1 * UNIT, uint64(block.timestamp - 1));
    }

    function test_TheEscrowCannotSettleSomethingThatWasNeverPaid() public {
        bytes32 id = _invoice(5 * UNIT, 0);
        vm.warp(block.timestamp + 30 hours);

        vm.expectRevert(abi.encodeWithSelector(InvoiceEscrow.InvoiceNotPaid.selector, id));
        vm.prank(merchant);
        escrow.settle(id);
    }

    function test_AMerchantCannotSettleTwice() public {
        bytes32 id = _invoice(5 * UNIT, 0);
        _approve(id);
        escrow.pay(id, address(policy));

        vm.warp(block.timestamp + 25 hours);
        vm.prank(merchant);
        escrow.settle(id);

        vm.expectRevert(abi.encodeWithSelector(InvoiceEscrow.InvoiceAlreadySettled.selector, id));
        vm.prank(merchant);
        escrow.settle(id);
    }

    /*//////////////////////////////////////////////////////////////
                            THE AGENT
    //////////////////////////////////////////////////////////////*/

    function test_TheAgentContractCanPayAnInvoice() public {
        bytes32 id = _invoice(12 * UNIT, 0);

        assertTrue(agent.pay(address(escrow), id));
        assertEq(token.balanceOf(address(escrow)), 12 * UNIT);
        assertEq(uint8(escrow.statusOf(id)), uint8(InvoiceEscrow.Status.Paid));
    }

    function test_TheAgentExplainsARefusalInsteadOfReverting() public {
        bytes32 id = _invoice(100 * UNIT, 0);

        (bool allowed, string memory reason) = agent.canPay(address(escrow), id);
        assertFalse(allowed);
        assertEq(reason, "the amount is above the single-payment cap");

        // Paying returns false rather than throwing.
        assertFalse(agent.pay(address(escrow), id));
    }

    function test_TheAgentHoldsNoMoney() public {
        bytes32 id = _invoice(12 * UNIT, 0);
        agent.pay(address(escrow), id);

        assertEq(token.balanceOf(address(agent)), 0);
    }

    function test_TheAgentCannotBypassTheOperatorCap() public {
        vm.prank(payer);
        policy.setOperatorCap(address(agent), 5 * UNIT);

        bytes32 id = _invoice(12 * UNIT, 0);
        assertFalse(agent.pay(address(escrow), id));
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_AnInvariant_ThePolicyNeverOverspendsItsDailyCap() public {
        // Fuzz: no sequence of approvals and releases can push the spend
        // above the cap, whatever the order.
        uint256 amount = bound(1 * UNIT, 1, CAP);
        bytes32 id = _invoice(amount, 0);

        vm.prank(operator);
        try policy.approve(address(escrow), id) {
            assertLe(policy.dailySpent(), CAP);
        } catch {
            assertLe(policy.dailySpent(), CAP);
        }

        assertLe(policy.dailySpent(), CAP);
        assertLe(policy.totalReserved(), policy.dailySpent());
    }

    function test_AnInvariant_ThePolicyNeverOverspendsItsBalance() public {
        bytes32 id = _invoice(1_000 * UNIT, 0);
        vm.prank(operator);
        try policy.approve(address(escrow), id) {} catch {}

        assertGe(token.balanceOf(address(policy)), policy.totalReserved());
    }

    function test_AnInvariant_ThePolicyNeverOverspendsThePerPayeeCap() public {
        uint256 amount = bound(1 * UNIT, 1, CAP);
        bytes32 id = _invoice(amount, 0);

        vm.prank(operator);
        try policy.approve(address(escrow), id) {} catch {}

        assertLe(policy.perPayeeSpent(payee), CAP);
    }
}
