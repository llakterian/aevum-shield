// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IInvoiceEscrow} from "./interfaces/IInvoiceEscrow.sol";

/**
 * @title PayPolicy
 * @notice A payer-side spending policy for stablecoin payments.
 *
 * @dev The problem this solves: an autonomous agent with a spending key can be
 * talked into paying anything. There is no cap, no allowlist, no rate limit,
 * no pause and no record you can hand to an auditor afterwards.
 *
 * This contract is the control plane. It holds the payer's funds and is the
 * only thing that can move them. Every payment out of it is checked against
 * rules the payer set in advance, and every decision, allowed or refused:
 * leaves a record on chain.
 *
 * Three properties the design leans on:
 *
 * 1. **The invoice's terms come from the escrow, not from the caller.** If
 *    the agent could describe a different payee to the policy than the one
 *    the money actually reaches, the allowlist would be decoration.
 *
 * 2. **Budget is spent at approval, not at settlement.** Two approvals
 *    racing against the same cap must not both pass. The budget comes back
 *    only if an approved payment is never claimed.
 *
 * 3. **Each authorisation is per invoice.** A reservation names the escrow
 *    it is good for and the exact amount, and it is spent by that escrow
 *    pulling it. Two invoices against the same merchant do not cancel each
 *    other out.
 *
 * Daily caps reset on UTC day boundaries rather than on a rolling window,
 * so a payer can say "50 tUSD8 a day" and know exactly when that day ends.
 */
contract PayPolicy is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Why a payment was allowed or refused.
    /// @dev The agent turns these into sentences, which is the whole point:
    /// a refusal that says "your daily cap is 50 tUSD8 and this invoice is
    /// 120 tUSD8" is a decision, not an error.
    enum Decision {
        Allowed,
        EscrowNotTrusted,
        InvoiceUnknown,
        InvoiceAlreadyPaid,
        InvoiceExpired,
        PayeeNotAllowed,
        PerPaymentCapExceeded,
        PerPayeeCapExceeded,
        DailyCapExceeded,
        OperatorCapExceeded,
        Paused,
        AlreadyApproved
    }

    /// @notice Where a reservation is in its life.
    enum ReservationState {
        /// @dev Approved and reserved. The money is still in this contract
        /// and the escrow has not taken it.
        Pending,
        /// @dev The escrow took the money. The budget stays spent.
        Consumed,
        /// @dev The reservation expired unused. The budget came back.
        Released
    }

    /// @notice A pending authorisation to pay one invoice.
    struct Reservation {
        address escrow;
        bytes32 invoiceId;
        address payee;
        address operator;
        uint256 amount;
        uint64 expiresAt;
        uint64 day;
        uint64 operatorDay;
        uint64 payeeDay;
        ReservationState state;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice One day, in seconds. Daily caps reset on UTC boundaries.
    uint256 public constant DAY = 24 hours;

    /// @notice How long an approved-but-unclaimed payment stays reserved.
    uint64 public constant RESERVATION_TTL = 1 hours;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The stablecoin this policy governs. Immutable on purpose: a
    /// policy that can be pointed at another token is a policy that can be
    /// pointed at a token with a transfer hook.
    IERC20 public immutable token;

    /// @dev The token's own decimals. tUSD8 uses 6, not 18.
    uint8 public immutable tokenDecimals;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Payees this payer is willing to pay.
    mapping(address => bool) public payeeAllowed;

    /// @notice Escrows this payer is willing to transact with. An escrow
    /// that is not registered cannot be paid, so a hostile contract cannot
    /// ask for money.
    mapping(address => bool) public escrowTrusted;

    /// @notice Operators allowed to request payments. This is where the AI
    /// agent gets its authority. And its own daily cap.
    mapping(address => bool) public operatorAllowed;

    /// @notice Per-operator daily cap. Zero means "no cap beyond the
    /// payer's own limits", which is a different thing from "no limit".
    mapping(address => uint256) public operatorDailyCap;

    /// @notice Amount an operator has spent today.
    mapping(address => uint256) public operatorDailySpent;

    /// @notice The UTC day the operator's spend belongs to.
    mapping(address => uint64) public operatorWindowDay;

    /// @notice Amount spent today to one payee.
    mapping(address => uint256) public perPayeeSpent;

    /// @notice The UTC day the per-payee spend belongs to.
    mapping(address => uint64) public perPayeeWindowDay;

    /// @notice Maximum amount in a single payment. Zero means no cap.
    uint256 public perPaymentCap;

    /// @notice Maximum amount in a single day, to one payee. Zero means no
    /// cap.
    uint256 public perPayeeCap;

    /// @notice Maximum amount in a single day, across all payees. Zero means
    /// no cap.
    uint256 public dailyCap;

    /// @notice Amount spent today.
    uint256 public dailySpent;

    /// @notice The UTC day the spend belongs to.
    uint64 public dailyWindowDay;

    /// @notice When true, no new payments can be approved. Withdrawals and
    /// reservation releases still work. A pause that trapped funds would be
    /// worse than no pause at all.
    bool public paused;

    /// @notice Outstanding reservations, by invoice id.
    mapping(bytes32 => Reservation) public reservations;

    /// @notice Every reservation id ever made, for enumeration.
    bytes32[] public reservationIds;

    /// @notice Invoice ids that already have a live reservation. Replay
    /// guard: the same invoice can never be approved twice.
    mapping(bytes32 => bool) public invoiceApproved;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PayeeSet(address indexed payee, bool allowed);
    event EscrowSet(address indexed escrow, bool trusted);
    event OperatorSet(address indexed operator, bool allowed);
    event OperatorCapSet(address indexed operator, uint256 cap);
    event CapsSet(uint256 perPayment, uint256 perPayee, uint256 daily);
    event PausedSet(bool paused);
    event ReservationMade(
        bytes32 indexed invoiceId,
        address indexed escrow,
        address indexed payee,
        uint256 amount,
        uint64 expiresAt
    );
    event ReservationReleased(bytes32 indexed invoiceId, address indexed escrow, uint256 amount);
    event PaymentPulled(bytes32 indexed invoiceId, address indexed escrow, uint256 amount);
    event DecisionRecorded(bytes32 indexed invoiceId, Decision decision, string reason);
    event Recovered(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOperator();
    error ReservationExpired(bytes32 invoiceId);
    error UnknownReservation(bytes32 invoiceId);
    error ZeroAmount();
    error NothingToRecover(address token);
    error NotTrustedEscrow(address escrow);
    error ReservationNotPending(bytes32 invoiceId);

    /// @notice A payment was refused by the policy.
    /// @param decision Which rule stopped it.
    /// @param reason A human-readable explanation.
    error PolicyDenied(Decision decision, string reason);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address token_, address owner_) Ownable(owner_) {
        if (token_ == address(0)) revert ZeroAmount();
        token = IERC20(token_);
        // Read decimals once, at construction. A token whose decimals changed
        // after deployment would silently rescale every cap.
        tokenDecimals = IERC20Metadata(token_).decimals();
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow or disallow a payee.
    function setPayee(address payee, bool allowed) external onlyOwner {
        payeeAllowed[payee] = allowed;
        emit PayeeSet(payee, allowed);
    }

    /// @notice Trust or distrust an escrow contract.
    function setEscrow(address escrow, bool trusted) external onlyOwner {
        escrowTrusted[escrow] = trusted;
        emit EscrowSet(escrow, trusted);
    }

    /// @notice Allow or disallow an operator, typically the AI agent.
    function setOperator(address operator, bool allowed) external onlyOwner {
        operatorAllowed[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @notice Set an operator's own daily cap, on top of the payer's.
    function setOperatorCap(address operator, uint256 cap) external onlyOwner {
        operatorDailyCap[operator] = cap;
        emit OperatorCapSet(operator, cap);
    }

    /// @notice Set the three caps. A cap of zero means "no cap".
    function setCaps(uint256 perPayment_, uint256 perPayee_, uint256 daily_) external onlyOwner {
        perPaymentCap = perPayment_;
        perPayeeCap = perPayee_;
        dailyCap = daily_;
        emit CapsSet(perPayment_, perPayee_, daily_);
    }

    /// @notice Pause or unpause new payments.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Withdraw tokens the policy is holding but will never pay out.
    /// @dev An approval that was never claimed leaves funds here. The owner
    /// can sweep them. This does not touch reserved funds.
    function recover(address token_, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token_ == address(0) || to == address(0)) revert ZeroAmount();
        uint256 reserved = totalReserved();
        uint256 balance = IERC20(token_).balanceOf(address(this));
        if (balance < reserved || balance - reserved < amount) revert NothingToRecover(token_);
        SafeERC20.safeTransfer(IERC20(token_), to, amount);
        emit Recovered(token_, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Amount currently reserved by live approvals.
    /// @dev Only pending reservations count. A consumed reservation has
    /// already left this contract, and a released one has been handed back
    /// to the budget.
    function totalReserved() public view returns (uint256 total) {
        uint256 len = reservationIds.length;
        for (uint256 i = 0; i < len; ++i) {
            Reservation storage r = reservations[reservationIds[i]];
            if (r.state == ReservationState.Pending) total += r.amount;
        }
    }

    /// @notice How many reservations have ever been made.
    function reservationCount() external view returns (uint256) {
        return reservationIds.length;
    }

    /// @notice The amount reserved against an invoice, if any.
    function reservationAmount(bytes32 invoiceId) external view returns (uint256) {
        return reservations[invoiceId].amount;
    }

    /// @notice The reservation id at an index.
    function reservationIdAt(uint256 index) external view returns (bytes32) {
        return reservationIds[index];
    }

    /// @notice Convert whole units to raw token units.
    function toUnits(uint256 whole) external view returns (uint256) {
        return whole * (10 ** tokenDecimals);
    }

    /// @notice Convert raw token units to whole units.
    function fromUnits(uint256 raw) external view returns (uint256) {
        return raw / (10 ** tokenDecimals);
    }

    /*//////////////////////////////////////////////////////////////
                                DAY WINDOWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The current UTC day index.
    function dayIndex() public view returns (uint256) {
        return block.timestamp / DAY;
    }

    /// @notice Roll the payer's day forward if it has ended.
    function _rollDay() internal {
        uint64 day = uint64(dayIndex());
        if (dailyWindowDay != day) {
            dailyWindowDay = day;
            dailySpent = 0;
        }
    }

    /// @notice The payer's spend today, without rolling.
    function _dailySpent() internal view returns (uint256) {
        return dailyWindowDay == uint64(dayIndex()) ? dailySpent : 0;
    }

    /// @notice Roll an operator's day forward if it has ended.
    function _rollOperatorDay(address operator) internal {
        uint64 day = uint64(dayIndex());
        if (operatorWindowDay[operator] != day) {
            operatorWindowDay[operator] = day;
            operatorDailySpent[operator] = 0;
        }
    }

    /// @notice An operator's spend today, without rolling.
    function _operatorSpent(address operator) internal view returns (uint256) {
        return operatorWindowDay[operator] == uint64(dayIndex()) ? operatorDailySpent[operator] : 0;
    }

    /// @notice Roll a payee's day forward if it has ended.
    function _rollPayeeDay(address payee) internal {
        uint64 day = uint64(dayIndex());
        if (perPayeeWindowDay[payee] != day) {
            perPayeeWindowDay[payee] = day;
            perPayeeSpent[payee] = 0;
        }
    }

    /// @notice The spend today to one payee, without rolling.
    function _payeeSpent(address payee) internal view returns (uint256) {
        return perPayeeWindowDay[payee] == uint64(dayIndex()) ? perPayeeSpent[payee] : 0;
    }

    /*//////////////////////////////////////////////////////////////
                                DECISION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ask whether a payment would be allowed, without doing it.
     * @param escrow The escrow that holds the invoice.
     * @param invoiceId The invoice.
     * @param operator Who is asking. The operator's own daily cap is
     * checked against this address, so the caller cannot borrow someone
     * else's budget.
     * @dev The agent calls this first, so it can tell the user *why* before
     * it tries. The answer is not a guarantee, `approve` re-checks
     * everything. But it is what makes the refusal explainable.
     *
     * The invoice's payee, amount and deadline are read from the escrow
     * itself. Taking them from the caller would let a confused or
     * compromised agent describe a different payee to the policy than the
     * one the money will actually reach.
     */
    function check(address escrow, bytes32 invoiceId, address operator)
        public
        view
        returns (Decision decision, string memory reason)
    {
        if (paused) return (Decision.Paused, "payments are paused");
        if (!escrowTrusted[escrow]) {
            return (Decision.EscrowNotTrusted, "that escrow is not on the trusted list");
        }

        (address payee, uint256 amount, uint64 deadline, bool paidIn) =
            _readInvoice(escrow, invoiceId);
        if (amount == 0) {
            return (Decision.InvoiceUnknown, "that invoice does not exist");
        }
        if (paidIn) {
            return (Decision.InvoiceAlreadyPaid, "that invoice has already been paid");
        }
        if (invoiceApproved[invoiceId]) {
            return (Decision.AlreadyApproved, "that invoice has already been approved");
        }
        if (deadline != 0 && deadline < block.timestamp) {
            return (Decision.InvoiceExpired, "that invoice has expired");
        }
        if (!payeeAllowed[payee]) {
            return (Decision.PayeeNotAllowed, "that payee is not on the allowed list");
        }
        if (perPaymentCap != 0 && amount > perPaymentCap) {
            return (Decision.PerPaymentCapExceeded, "the amount is above the single-payment cap");
        }
        if (perPayeeCap != 0 && _payeeSpent(payee) + amount > perPayeeCap) {
            return
                (Decision.PerPayeeCapExceeded, "the amount is above the cap for that payee today");
        }
        if (dailyCap != 0 && _dailySpent() + amount > dailyCap) {
            return (Decision.DailyCapExceeded, "the amount is above the daily cap");
        }
        uint256 opCap = operatorDailyCap[operator];
        if (opCap != 0 && _operatorSpent(operator) + amount > opCap) {
            return
                (Decision.OperatorCapExceeded, "the amount is above the operator's own daily cap");
        }
        return (Decision.Allowed, "allowed");
    }

    /// @notice Read an invoice's terms from the escrow that holds it.
    /// @dev A revert from the escrow. An unknown invoice, comes back as
    /// zeroes rather than bubbling up, so the agent gets a decision it can
    /// explain instead of a stack trace.
    function _readInvoice(address escrow, bytes32 invoiceId)
        private
        view
        returns (address payee, uint256 amount, uint64 deadline, bool paidIn)
    {
        try IInvoiceEscrow(escrow).invoiceDetails(invoiceId) returns (
            address p, uint256 a, uint64 d, bool paid
        ) {
            return (p, a, d, paid);
        } catch {
            return (address(0), 0, 0, false);
        }
    }

    /// @notice Spend left in the current day.
    function dailyRemaining() external view returns (uint256) {
        if (dailyCap == 0) return type(uint256).max;
        uint256 spent = _dailySpent();
        return spent >= dailyCap ? 0 : dailyCap - spent;
    }

    /// @notice Spend left today for one payee.
    function perPayeeRemaining(address payee) external view returns (uint256) {
        if (perPayeeCap == 0) return type(uint256).max;
        uint256 spent = _payeeSpent(payee);
        return spent >= perPayeeCap ? 0 : perPayeeCap - spent;
    }

    /// @notice Spend left today for one operator.
    function operatorRemaining(address operator) external view returns (uint256) {
        uint256 cap = operatorDailyCap[operator];
        if (cap == 0) return type(uint256).max;
        uint256 spent = _operatorSpent(operator);
        return spent >= cap ? 0 : cap - spent;
    }

    /*//////////////////////////////////////////////////////////////
                                APPROVAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Approve one invoice: check the policy, reserve the budget and
     * let exactly one escrow pull exactly that amount.
     *
     * @dev The reservation is the authorisation. The escrow named in it can
     * pull that amount and no more, once, and after it does the
     * authorisation is spent.
     *
     * The invoice's terms come from the escrow, not from the caller. See
     * `check` for why that matters.
     */
    function approve(address escrow, bytes32 invoiceId) external nonReentrant {
        if (!operatorAllowed[msg.sender] && msg.sender != owner()) revert NotOperator();

        (Decision decision, string memory reason) = check(escrow, invoiceId, msg.sender);
        if (decision != Decision.Allowed) {
            emit DecisionRecorded(invoiceId, decision, reason);
            revert PolicyDenied(decision, reason);
        }

        (address payee, uint256 amount,,) = _readInvoice(escrow, invoiceId);
        if (amount == 0) revert ZeroAmount();

        // Roll the day forward before accounting for it.
        _rollDay();
        _rollOperatorDay(msg.sender);
        _rollPayeeDay(payee);

        // Reserve the budget now, not at settlement. Two approvals racing
        // against the same cap must not both pass.
        dailySpent += amount;
        operatorDailySpent[msg.sender] += amount;
        perPayeeSpent[payee] += amount;

        uint64 expiresAt = uint64(block.timestamp) + RESERVATION_TTL;
        reservations[invoiceId] = Reservation({
            escrow: escrow,
            invoiceId: invoiceId,
            payee: payee,
            operator: msg.sender,
            amount: amount,
            expiresAt: expiresAt,
            day: dailyWindowDay,
            operatorDay: operatorWindowDay[msg.sender],
            payeeDay: perPayeeWindowDay[payee],
            state: ReservationState.Pending
        });
        reservationIds.push(invoiceId);
        invoiceApproved[invoiceId] = true;

        emit ReservationMade(invoiceId, escrow, payee, amount, expiresAt);
        emit DecisionRecorded(invoiceId, Decision.Allowed, reason);
    }

    /**
     * @notice Move the reserved amount for one invoice to the escrow that
     * owns it.
     * @dev Anyone may call this, but the destination is fixed by the
     * reservation, so a caller cannot redirect the money. The escrow's own
     * `pay` function is the normal caller.
     */
    function pull(bytes32 invoiceId, address escrow)
        external
        nonReentrant
        returns (uint256 amount)
    {
        Reservation storage r = reservations[invoiceId];
        if (r.amount == 0 || r.state == ReservationState.Released) {
            revert UnknownReservation(invoiceId);
        }
        if (r.state != ReservationState.Pending) revert ReservationNotPending(invoiceId);
        if (r.escrow != escrow) revert NotTrustedEscrow(escrow);

        r.state = ReservationState.Consumed;
        amount = r.amount;

        token.safeTransfer(escrow, amount);
        emit PaymentPulled(invoiceId, escrow, amount);
    }

    /**
     * @notice Refund a paid invoice.
     * @dev The policy is the payer of record, so it is the policy that has
     * to call the escrow. The payer does this through the policy, and the
     * policy checks that this invoice is one of its own before it does.
     *
     * A refunded payment still counts against the budget for the day.
     * Refunds return the money; they must not hand the agent fresh budget
     * to spend again.
     */
    function refund(address escrow, bytes32 invoiceId) external nonReentrant {
        Reservation storage r = reservations[invoiceId];
        if (r.amount == 0 || r.state == ReservationState.Released) {
            revert UnknownReservation(invoiceId);
        }
        if (r.escrow != escrow) revert NotTrustedEscrow(escrow);
        if (msg.sender != owner() && msg.sender != r.operator) revert NotOperator();

        IInvoiceEscrow(escrow).refund(invoiceId);
    }

    /// @notice Cancel an approval that was never claimed and hand the
    /// budget back.
    function release(bytes32 invoiceId) external nonReentrant {
        Reservation storage r = reservations[invoiceId];
        if (r.amount == 0 || r.state != ReservationState.Pending) {
            revert UnknownReservation(invoiceId);
        }
        if (msg.sender != owner() && msg.sender != r.operator) revert NotOperator();
        if (block.timestamp < r.expiresAt) revert ReservationExpired(invoiceId);

        _releaseReservation(invoiceId, r);
    }

    /// @notice Release every reservation whose time has run out.
    function releaseExpired() external returns (uint256 count) {
        uint256 len = reservationIds.length;
        for (uint256 i = 0; i < len; ++i) {
            bytes32 id = reservationIds[i];
            Reservation storage r = reservations[id];
            if (r.amount != 0 && r.state == ReservationState.Pending) {
                if (block.timestamp >= r.expiresAt) {
                    _releaseReservation(id, r);
                    count++;
                }
            }
        }
    }

    function _releaseReservation(bytes32 invoiceId, Reservation storage r) internal {
        r.state = ReservationState.Released;
        invoiceApproved[invoiceId] = false;

        // Hand the budget back. But only to the day it was taken from. If
        // the day has since rolled, that day's spend has already been
        // cleared and subtracting from today's would corrupt it.
        _rollDay();
        if (r.day == dailyWindowDay && dailySpent >= r.amount) dailySpent -= r.amount;

        _rollOperatorDay(r.operator);
        if (
            r.operatorDay == operatorWindowDay[r.operator]
                && operatorDailySpent[r.operator] >= r.amount
        ) {
            operatorDailySpent[r.operator] -= r.amount;
        }

        _rollPayeeDay(r.payee);
        if (r.payeeDay == perPayeeWindowDay[r.payee] && perPayeeSpent[r.payee] >= r.amount) {
            perPayeeSpent[r.payee] -= r.amount;
        }

        emit ReservationReleased(invoiceId, r.escrow, r.amount);
    }
}
