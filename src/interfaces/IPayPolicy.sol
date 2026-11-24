// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * @title IPayPolicy
 * @notice The part of a payer-side policy that a merchant escrow needs.
 * @dev The escrow asks the policy for the money. The policy decides how
 * much moves, and the escrow only receives the exact amount the policy
 * reserved for that one invoice.
 *
 * An ERC-20 allowance would have been the obvious mechanism and it is the
 * wrong one: the allowance is keyed by (owner, spender), not by invoice, so
 * approving a second invoice for the same escrow silently cancels the
 * first one's authorisation. A per-invoice pull keeps every authorisation
 * independent, and it means the policy is the only thing that ever moves
 * the payer's money.
 */
interface IPayPolicy {
    /**
     * @notice Move the reserved amount for one invoice to the escrow that
     * owns it.
     * @param invoiceId The invoice being paid.
     * @param escrow The escrow asking. It must be the one the reservation
     * was made against.
     * @return amount The amount transferred, in raw token units.
     */
    function pull(bytes32 invoiceId, address escrow) external returns (uint256 amount);
}
