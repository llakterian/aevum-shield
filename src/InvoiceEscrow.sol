// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IInvoiceEscrow} from "./interfaces/IInvoiceEscrow.sol";
import {IPayPolicy} from "./interfaces/IPayPolicy.sol";

/**
 * @title InvoiceEscrow
 * @notice A merchant-side invoice and escrow.
 *
 * @dev The merchant holds the funds, not the payer. That is the whole point
 * of an escrow: the merchant does not have to trust the payer, and the payer
 * does not have to trust the merchant with money it has not yet paid.
 *
 * The payment arrives by the escrow *pulling* from the payer's policy
 * contract. The escrow does not trust the payer to send the right amount:
 * it asks the policy for the money, and the policy moves exactly the amount
 * it reserved for that invoice. The escrow checks its own balance before
 * and after, so a policy that claims to have paid but did not is caught.
 *
 * Lifecycle:
 *
 *   createInvoice  ->  (payer approves via its policy)  ->  pay
 *                                                           |
 *                                            +--------------+--------------+
 *                                            |                             |
 *                                        settle                        refund
 *                                       (to payee)              (by the payer)
 *
 * The dispute window starts when the money arrives, not when the invoice
 * was written, so a merchant cannot create an invoice early and settle it
 * before the payer has had any time to object.
 */
contract InvoiceEscrow is Ownable2Step, ReentrancyGuard, IInvoiceEscrow {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice One invoice.
    struct Invoice {
        address payee;
        address payer;
        uint256 amount;
        uint64 deadline;
        uint64 createdAt;
        uint64 paidAt;
        uint64 disputeWindow;
        uint256 paid;
        bool settled;
        bool refunded;
        bool paidIn;
    }

    /// @notice The state of an invoice.
    enum Status {
        None,
        Created,
        Paid,
        Settled,
        Refunded
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice How long the payer may dispute after payment, unless the
    /// merchant sets otherwise. Zero means the merchant settles at will.
    uint64 public constant DEFAULT_DISPUTE_WINDOW = 24 hours;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The stablecoin this escrow holds.
    IERC20 public immutable token;

    /// @dev The token's own decimals. tUSD8 uses 6, not 18.
    uint8 public immutable tokenDecimals;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The dispute window applied to new invoices.
    uint64 public disputeWindow = DEFAULT_DISPUTE_WINDOW;

    /// @notice Every invoice, by id.
    mapping(bytes32 => Invoice) public invoices;

    /// @notice Every invoice id ever created, for enumeration.
    bytes32[] public invoiceIds;

    /// @notice Per-merchant nonce, so two invoices can never collide.
    uint256 public nonce;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event InvoiceCreated(
        bytes32 indexed invoiceId, address indexed payee, uint256 amount, uint64 deadline
    );
    event InvoicePaid(bytes32 indexed invoiceId, address indexed payer, uint256 amount);
    event InvoiceSettled(bytes32 indexed invoiceId, address indexed payee, uint256 amount);
    event InvoiceRefunded(bytes32 indexed invoiceId, address indexed payer, uint256 amount);
    event DisputeWindowSet(uint64 window);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnknownInvoice(bytes32 invoiceId);
    error InvoiceAlreadyPaid(bytes32 invoiceId);
    error InvoiceNotPaid(bytes32 invoiceId);
    error InvoiceAlreadySettled(bytes32 invoiceId);
    error InvoiceAlreadyRefunded(bytes32 invoiceId);
    error InvoiceExpired(bytes32 invoiceId);
    error DisputeWindowOpen(bytes32 invoiceId);
    error NotPayer(bytes32 invoiceId);
    error ZeroAmount();
    error DeadlineInThePast();
    error AmountMismatch(uint256 expected, uint256 received);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address token_, address owner_) Ownable(owner_) {
        if (token_ == address(0)) revert ZeroAmount();
        token = IERC20(token_);
        tokenDecimals = IERC20Metadata(token_).decimals();
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the dispute window for new invoices.
    /// @dev The window is copied into each invoice when it is created, so
    /// changing this never changes an existing invoice.
    function setDisputeWindow(uint64 window) external onlyOwner {
        disputeWindow = window;
        emit DisputeWindowSet(window);
    }

    /*//////////////////////////////////////////////////////////////
                                INVOICES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create an invoice.
     * @param payee Who receives the money on settlement.
     * @param amount How much, in raw token units.
     * @param deadline When the invoice stops being payable. Zero means no
     * deadline.
     * @return invoiceId The id the payer will use.
     */
    function createInvoice(address payee, uint256 amount, uint64 deadline)
        external
        onlyOwner
        returns (bytes32 invoiceId)
    {
        if (payee == address(0) || amount == 0) revert ZeroAmount();
        if (deadline != 0 && deadline < block.timestamp) revert DeadlineInThePast();

        nonce++;
        invoiceId = keccak256(
            abi.encode(address(this), block.chainid, address(this), nonce, payee, amount, deadline)
        );

        invoices[invoiceId] = Invoice({
            payee: payee,
            payer: address(0),
            amount: amount,
            deadline: deadline,
            createdAt: uint64(block.timestamp),
            paidAt: 0,
            disputeWindow: disputeWindow,
            paid: 0,
            settled: false,
            refunded: false,
            paidIn: false
        });
        invoiceIds.push(invoiceId);

        emit InvoiceCreated(invoiceId, payee, amount, deadline);
    }

    /// @notice An invoice's current status.
    function statusOf(bytes32 invoiceId) external view returns (Status) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.amount == 0) return Status.None;
        if (inv.refunded) return Status.Refunded;
        if (inv.settled) return Status.Settled;
        if (inv.paidIn) return Status.Paid;
        return Status.Created;
    }

    /**
     * @notice The invoice's terms, as this escrow holds them.
     * @dev A payer's policy reads the invoice from here rather than trusting
     * the agent to describe it. Both sides read the same storage, so they
     * cannot disagree about who is being paid or how much.
     */
    function invoiceDetails(bytes32 invoiceId)
        external
        view
        returns (address payee, uint256 amount, uint64 deadline, bool paidIn)
    {
        Invoice storage inv = invoices[invoiceId];
        if (inv.amount == 0) revert UnknownInvoice(invoiceId);
        return (inv.payee, inv.amount, inv.deadline, inv.paidIn);
    }

    /// @notice When the payer may dispute this invoice, if it has been paid.
    function disputeDeadline(bytes32 invoiceId) external view returns (uint64) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.amount == 0) revert UnknownInvoice(invoiceId);
        if (!inv.paidIn) return 0;
        return uint64(inv.paidAt) + inv.disputeWindow;
    }

    /*//////////////////////////////////////////////////////////////
                                PAYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pull the payment for an invoice from the payer's policy.
     * @dev The payer must have approved this exact invoice, and that
     * approval left a reservation behind. The policy moves exactly the
     * authorised amount and the reservation is spent afterwards, so this
     * cannot be replayed and cannot be used to take more than was approved.
     *
     * Anyone may call this: it only succeeds if the reservation exists.
     */
    function pay(bytes32 invoiceId, address policy) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.amount == 0) revert UnknownInvoice(invoiceId);
        if (inv.paidIn) revert InvoiceAlreadyPaid(invoiceId);
        if (inv.settled || inv.refunded) revert InvoiceAlreadySettled(invoiceId);
        if (inv.deadline != 0 && inv.deadline < block.timestamp) {
            revert InvoiceExpired(invoiceId);
        }

        uint256 expected = inv.amount;
        uint256 balanceBefore = token.balanceOf(address(this));

        uint256 reported = IPayPolicy(policy).pull(invoiceId, address(this));

        // Check what actually arrived, not what the policy said it sent.
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != expected) revert AmountMismatch(expected, received);
        if (reported != expected) revert AmountMismatch(expected, reported);

        inv.payer = policy;
        inv.paid = received;
        inv.paidAt = uint64(block.timestamp);
        inv.paidIn = true;

        emit InvoicePaid(invoiceId, policy, received);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Release the payment to the payee.
     * @dev Only the merchant may settle, and only after the dispute window
     * has closed. Settling early is how merchants steal from payers, so
     * the window is not optional.
     */
    function settle(bytes32 invoiceId) external onlyOwner nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.amount == 0) revert UnknownInvoice(invoiceId);
        if (!inv.paidIn) revert InvoiceNotPaid(invoiceId);
        if (inv.settled) revert InvoiceAlreadySettled(invoiceId);
        if (inv.refunded) revert InvoiceAlreadyRefunded(invoiceId);

        uint64 disputeUntil = uint64(inv.paidAt) + inv.disputeWindow;
        if (disputeUntil > block.timestamp) revert DisputeWindowOpen(invoiceId);

        inv.settled = true;

        token.safeTransfer(inv.payee, inv.paid);
        emit InvoiceSettled(invoiceId, inv.payee, inv.paid);
    }

    /**
     * @notice Return the payment to the payer.
     * @dev The payer may refund at any time before settlement. After
     * settlement there is nothing left to refund. The payer of record is
     * the payer's policy contract, so the policy is the one that calls this.
     */
    function refund(bytes32 invoiceId) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        if (inv.amount == 0) revert UnknownInvoice(invoiceId);
        if (!inv.paidIn) revert InvoiceNotPaid(invoiceId);
        if (inv.refunded) revert InvoiceAlreadyRefunded(invoiceId);
        if (inv.settled) revert InvoiceAlreadySettled(invoiceId);

        address payer = inv.payer;
        if (msg.sender != payer) revert NotPayer(invoiceId);

        inv.refunded = true;

        token.safeTransfer(payer, inv.paid);
        emit InvoiceRefunded(invoiceId, payer, inv.paid);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice How many invoices this merchant has created.
    function invoiceCount() external view returns (uint256) {
        return invoiceIds.length;
    }

    /// @notice The invoice id at an index.
    function invoiceIdAt(uint256 index) external view returns (bytes32) {
        return invoiceIds[index];
    }

    /// @notice Tokens this escrow is holding that belong to nobody.
    function idleBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
