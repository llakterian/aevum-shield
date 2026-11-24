// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * @title IInvoiceEscrow
 * @notice The part of a merchant escrow that a payer's policy needs.
 * @dev Kept deliberately small and stable. The policy reads the invoice
 * from the escrow rather than trusting the caller to describe it — if the
 * agent can lie about the payee or the deadline, the allowlist is not a
 * control, it is a suggestion.
 */
interface IInvoiceEscrow {
    /// @notice The invoice's terms, as the escrow itself holds them.
    function invoiceDetails(bytes32 invoiceId)
        external
        view
        returns (address payee, uint256 amount, uint64 deadline, bool paidIn);

    /// @notice Return a paid invoice to the payer. Only the payer of record
    /// may call this.
    function refund(bytes32 invoiceId) external;
}
