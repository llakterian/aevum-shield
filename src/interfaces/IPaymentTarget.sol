// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * @title IPaymentTarget
 * @notice Something the payer-side policy can pay.
 */
interface IPaymentTarget {
    /// @notice Ask the policy for the money reserved against this invoice.
    /// @param invoiceId The invoice being paid.
    /// @param policy The policy that holds the reservation.
    function pay(bytes32 invoiceId, address policy) external;
}
