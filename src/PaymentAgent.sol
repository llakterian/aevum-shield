// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PayPolicy} from "./PayPolicy.sol";
import {IPaymentTarget} from "./interfaces/IPaymentTarget.sol";

/**
 * @title PaymentAgent
 * @notice The on-chain half of an AI payment agent.
 *
 * @dev The agent holds **no money and has no key that can move money**. It
 * has exactly one power: to ask the payer's policy to approve an invoice.
 * Everything that makes that safe — the allowlist, the caps, the pause, the
 * deadline — lives in the policy and is enforced there.
 *
 * That split is the point. If the agent had the funds, a prompt injection
 * would be a financial event. If the agent has a request, a prompt injection
 * is a request that a policy may refuse. The agent's job is to make the
 * refusal legible: it asks the policy *why* before it tries, so it can say
 * "your daily cap is 50 tUSD8 and this invoice is 120" instead of failing
 * with a stack trace.
 *
 * Anyone may trigger a payment through this contract. That is deliberate:
 * the agent's authority is bounded by the policy's caps, so there is
 * nothing to gain by being the only caller. The caps are the control, not
 * the caller list.
 */
contract PaymentAgent {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The payer's policy. This contract is an operator on it.
    address public immutable policy;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PaymentRequested(bytes32 indexed invoiceId, address indexed target, uint256 amount);
    event PaymentRefused(bytes32 indexed invoiceId, string reason);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address policy_) {
        if (policy_ == address(0)) revert ZeroAddress();
        policy = policy_;
    }

    /*//////////////////////////////////////////////////////////////
                                DECISION
    //////////////////////////////////////////////////////////////*/

    /// @notice Ask the policy whether this agent may pay an invoice.
    /// @return allowed Whether the payment would be permitted.
    /// @return reason A sentence explaining the answer.
    function canPay(address target, bytes32 invoiceId)
        public
        view
        returns (bool allowed, string memory reason)
    {
        (PayPolicy.Decision decision, string memory why) =
            PayPolicy(policy).check(target, invoiceId, address(this));
        return (decision == PayPolicy.Decision.Allowed, why);
    }

    /*//////////////////////////////////////////////////////////////
                                PAYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ask the policy to approve an invoice, and pay it if it says yes.
     * @dev A refusal is returned as `false` with the reason, not as a
     * revert. The agent's job is to explain, and an exception is a much
     * worse explanation than a sentence.
     */
    function pay(address target, bytes32 invoiceId) external returns (bool) {
        (PayPolicy.Decision decision, string memory reason) =
            PayPolicy(policy).check(target, invoiceId, address(this));
        if (decision != PayPolicy.Decision.Allowed) {
            emit PaymentRefused(invoiceId, reason);
            return false;
        }

        PayPolicy(policy).approve(target, invoiceId);
        uint256 amount = PayPolicy(policy).reservationAmount(invoiceId);
        IPaymentTarget(target).pay(invoiceId, policy);

        emit PaymentRequested(invoiceId, target, amount);
        return true;
    }
}
