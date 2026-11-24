# Threat model

**Aevum Shield** — payments under enforceable policy on QDay Aevum Testnet.

This document is the argument that the control plane is safe. It lists what
is being protected, who is trusted and who is not, what an attacker would
try, and what actually stops them. Where something is *not* stopped, that
is written down too, under **Accepted risks**.

It is a design-time analysis, not an audit. No independent audit has been
performed. See [Accepted risks](#accepted-risks).

---

## 1. What is being protected

| # | Asset | Why it matters |
| --- | --- | --- |
| A1 | The payer's stablecoin balance held in the `PayPolicy` | The money a company has left an agent to spend. |
| A2 | The merchant's funds held in the `InvoiceEscrow` | The merchant's side of the trade. |
| A3 | The integrity of the policy rules | The allowlist, the caps, the pause. If these can be edited by the thing they constrain, they are not controls. |
| A4 | The audit trail | The `DecisionRecorded`, `ReservationMade`, `PaymentPulled` and `Invoice*` events. A decision that cannot be explained cannot be trusted. |
| A5 | The payer's right to dispute | A merchant must not be able to take the money and close the books before the payer can object. |

---

## 2. Who is trusted

| Party | Trust level | Why |
| --- | --- | --- |
| **The payer** | Trusted principal | Owns the `PayPolicy`. Sets the rules and can change them. Everything else in this document assumes the payer is not the attacker. |
| **The token contract** | Trusted | The policy's token is immutable. A token with a transfer hook could behave differently from what the escrow expects. |
| **The merchant** | Semi-trusted | Owns the `InvoiceEscrow`. Wants the money. The escrow's behaviour is constrained by the fact that the payer chose to register it and can refuse to pay it. |
| **The operator / agent** | **Untrusted** | This is the point of the whole project. The agent is assumed to be compromised, confused or prompt-injected. It is assumed to act against the payer's interests. |
| **The escrow contract** | Semi-trusted, registered | The payer registers each escrow it is willing to transact with. An unregistered escrow is refused before anything is read from it. |

The agent being untrusted is not a rhetorical choice. It is the design
constraint the contracts are built around: **the agent holds no money and
has no key that can move money.** Its only power is to ask the policy to
approve an invoice.

---

## 3. Attack surface

There are four ways to reach the money.

1. **Approval** — the agent asks the policy to reserve funds for an invoice.
2. **Pull** — an escrow asks the policy for the money it reserved.
3. **Settlement** — the merchant asks the escrow to release the money.
4. **Recovery** — the payer asks the policy to return unreserved funds.

Each is analysed below, followed by the attacks that do not fit a single
path.

---

### 3.1 Approval

`PayPolicy.approve(escrow, invoiceId)`

The policy reads the invoice's payee, amount and deadline **from the
escrow**, not from the caller.

| # | Attack | Mitigation | Test |
| --- | --- | --- | --- |
| AT-1 | The agent describes a different payee to the policy than the one the money reaches. | The policy reads `payee`, `amount` and `deadline` from the escrow itself. The agent cannot describe anything. | `test_RefusesAPayeeThatIsNotAllowed` |
| AT-2 | The agent inflates or deflates the amount. | Same. The amount comes from the escrow. | `test_TheEscrowPullsExactlyWhatWasApproved` |
| AT-3 | A hostile contract asks for money. | `escrowTrusted` is an allowlist. An unregistered escrow is refused *before* any invoice is read from it. | `test_RefusesAnUntrustedEscrow` |
| AT-4 | Two approvals race against the same cap and both pass. | The budget is spent **at approval**, not at settlement. The second approval sees the first one's spend. | `test_AnInvariant_ThePolicyNeverOverspendsItsDailyCap` |
| AT-5 | The same invoice is approved twice. | `invoiceApproved` plus the reservation's state. A consumed or released reservation cannot be re-approved. | `test_RefusesToApproveTheSameInvoiceTwice` |
| AT-6 | An agent borrows another operator's budget. | The operator's cap is checked against `msg.sender`, and `check` takes the asking operator explicitly so a caller cannot pass someone else's address. | `test_TheOperatorCapIsCheckedAgainstTheAskingOperator` |
| AT-7 | A stranger approves anything. | Only the owner and explicitly registered operators may approve. | `test_AStrangerCannotApproveAnything` |
| AT-8 | The agent pays an expired invoice. | The deadline is checked at approval, and the escrow checks it again at pull. | `test_RefusesAnExpiredInvoice`, `test_AnExpiredInvoiceCannotBePaid` |
| AT-9 | The agent promotes itself to owner. | The agent is an *operator*, not an owner. Operator rights are strictly smaller: an operator can request approvals, not edit the allowlist or the caps. | `test_TheAgentHoldsNoMoney` |

### 3.2 Pull

`PayPolicy.pull(invoiceId, escrow)` and `InvoiceEscrow.pay(invoiceId, policy)`

The escrow asks the policy for the money; the policy moves it.

| # | Attack | Mitigation | Test |
| --- | --- | --- | --- |
| AT-10 | The escrow takes more than was approved. | The reservation names one escrow and one exact amount. `pull` transfers `r.amount` and marks the reservation `Consumed`. | `test_TheEscrowPullsExactlyWhatWasApproved` |
| AT-11 | The escrow takes the money more than once. | `pull` reverts on a consumed reservation. | `test_AnInvoiceCannotBePaidTwice` |
| AT-12 | A third party pulls a reservation that is not theirs. | `pull` requires `msg.sender == r.escrow`. | `test_AnEscrowCannotPullAnotherEscrowsReservation` |
| AT-13 | **One merchant's second invoice silently cancels the first.** | Each authorisation is a per-invoice reservation. An ERC-20 allowance is keyed by `(owner, spender)`, so approving a second invoice for the same merchant would have overwritten the first one's allowance. This was a real bug, found by the tests; the reservation design replaced it. | `test_TwoInvoicesForTheSameEscrowCanBothBePaid` |
| AT-14 | A "policy" that says it paid but did not. | The escrow checks its **own balance before and after** the pull and requires the delta to equal the invoice amount exactly. It does not trust the return value. | `InvoiceEscrow.pay` |
| AT-15 | Reentrancy through the token or the escrow. | `ReentrancyGuard` on every state-changing entry point in both contracts. | — |

### 3.3 Settlement and refund

`InvoiceEscrow.settle(invoiceId)` and `InvoiceEscrow.refund(invoiceId)`

| # | Attack | Mitigation | Test |
| --- | --- | --- | --- |
| AT-16 | The merchant settles before the payer can dispute. | `settle` reverts while the dispute window is open. The window starts when the **payment arrives**, not when the invoice was written — otherwise a merchant could write an invoice early and settle the moment the money landed. | `test_TheFullHappyPath`, `test_TheDisputeWindowStartsWhenThePaymentArrives` |
| AT-17 | The merchant refunds itself. | `refund` requires `msg.sender == inv.payer`, and the payer of record is the `PayPolicy` contract, not the merchant. The merchant cannot call it. | `test_AMerchantCannotRefund` |
| AT-18 | The merchant settles twice. | `settled` is checked. | `test_AMerchantCannotSettleTwice` |
| AT-19 | The merchant creates an invoice for someone else. | `createInvoice` is `onlyOwner`. | `test_AMerchantCannotCreateAnInvoiceForSomebodyElse` |
| AT-20 | A refund lets the agent spend the same allowance again. | A refund returns the money but **does not** restore the budget. | `test_ARefundDoesNotHandBackTheBudget` |

### 3.4 Recovery and the budget

`PayPolicy.recover(token, to, amount)` and `PayPolicy.release(invoiceId)`

| # | Attack | Mitigation | Test |
| --- | --- | --- | --- |
| AT-21 | The payer recovers funds that are reserved. | `recover` is capped at `balance - totalReserved()`, and `totalReserved` counts only **pending** reservations. A consumed one has already left the contract; a released one went back to the budget. | `test_RecoverStopsExactlyAtTheReservedAmount`, `test_ConsumedFundsAreNoLongerReserved` |
| AT-22 | A reservation is released before it expires, and the budget is handed back early. | `release` reverts until the reservation's TTL has passed. `releaseExpired` only touches reservations past their TTL. | `test_AReservationCannotBeReleasedBeforeItExpires` |
| AT-23 | Releasing an old reservation corrupts today's budget. | Each reservation records the UTC day it was charged to. A release only gives the budget back to that day; if the day has rolled, that day's spend has already been cleared. | `test_ReleasingAfterTheDayRollsDoesNotCorruptTodaysBudget` |
| AT-24 | A stranger releases somebody else's reservation. | Only the owner or the operator that made the reservation may release it. | `test_OnlyTheOwnerOrTheOperatorCanRelease` |

---

## 4. The pause

`paused` stops **new approvals** and nothing else.

That is deliberate. A pause that also trapped funds would be worse than no
pause: the payer would have to either keep the agent running or find a
privileged path to get the money back, and every privileged path is another
thing to get wrong. With this design, a paused policy still lets the payer
release expired reservations and sweep unreserved funds.

The risk of the opposite choice — a pause that cannot be undone — is
handled by `Ownable2Step`: transferring ownership takes two transactions,
so a hijacked ownership change can be noticed and refused.

---

## 5. What the event log proves

Every decision leaves a record:

| Event | What it establishes |
| --- | --- |
| `DecisionRecorded(invoiceId, decision, reason)` | That a decision was made, what it was, and — for a refusal — the rule that produced it. The reason is a sentence, not a number. |
| `ReservationMade(invoiceId, escrow, payee, amount, expiresAt)` | That a specific amount was committed to a specific payee through a specific escrow, and when it would lapse. |
| `PaymentPulled(invoiceId, escrow, amount)` | That the money moved, to whom, and how much. |
| `ReservationReleased(invoiceId, escrow, amount)` | That a commitment was withdrawn and the budget handed back. |
| `InvoiceCreated` / `InvoicePaid` / `InvoiceSettled` / `InvoiceRefunded` | The merchant side of the trade, in order. |

Together these reconstruct the whole payment history without any off-chain
database. An auditor does not need to trust the operator's logs, because
the logs are the chain.

---

## 6. Accepted risks

These are real. They are listed because a threat model that claims to have
no residual risk is not a threat model.

1. **The payer can change the rules at any time.** A policy is only as
   strong as its owner. If the payer's own key is compromised, the
   allowlist and the caps can be edited in one transaction. `Ownable2Step`
   slows an ownership *transfer* but does nothing about the owner calling
   `setCaps` directly. A timelock on the owner's powers would close this
   and is the obvious next step.
2. **No independent audit.** The tests are thorough and the design is
   conservative, but the contracts have not been reviewed by a third party.
   For a production deployment, that is a prerequisite, not a nice-to-have.
3. **A merchant can grief with invoices.** A merchant can create many
   invoices that the agent approves and nobody ever pays. The reservation
   TTL bounds this to one hour per invoice, and the budget is held in the
   meantime. A per-merchant invoice-count limit would close it.
4. **An operator can spend its whole budget in one transaction.** The caps
   bound the amount, not the number of transactions. A transaction-count
   limit per day would close this.
5. **The token contract is trusted.** The policy's token is immutable, which
   is good, but the escrow checks for an exact balance delta, so a
   fee-on-transfer token would make settlement fail rather than silently
   underpay. This is safe-by-failing, but it is a dependency.
6. **Daily caps reset on UTC midnight, not on a rolling 24 hours.** A payer
   who spends at 23:59 and again at 00:01 can spend twice as much as they
   intended across the boundary. This was chosen deliberately — "50 tUSD8 a
   day" should mean a day, and a user should be able to say when it ends —
   but it is a real property, not a subtlety.
7. **The dispute window is a fixed number of seconds.** On the testnet
   demonstration it is set to 60 seconds so the demo does not have to wait
   a day. A production deployment would use 24 hours or a period chosen
   per invoice.
8. **The owner can sweep unreserved funds at any time.** That is the
   point of `recover` — a payer must be able to get their money back — but
   it does mean a compromised owner key can take the unreserved balance.

---

## 7. What would be next

In rough order of value:

1. A timelock on `setCaps`, `setPayee`, `setEscrow` and `setOperator`, so
   a compromised owner key cannot immediately widen the rules.
2. A per-invoice dispute period chosen by the payer, not only by the
   merchant.
3. A transaction-count cap per operator per day.
4. EIP-712 signed authorisations, so a payment can be authorised by an
   off-chain signer without giving that signer a key on-chain.
5. An independent audit.
