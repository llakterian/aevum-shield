# Aevum Builder Challenge #1: project plan

**QDay Aevum Builder Challenge #1: Stablecoin Payments Hackathon on Aevum**

- Prize pool: **$1,500 USDT**: $800 first, $500 second, $200 third
- Build period: **Nov 16 to Dec 11, 2026**
- Submissions close: **Dec 11, 2026, 08:00 UTC**
- Judging: Dec 12 to 14. Demo Day: **Dec 15, 06:00 UTC** (top 5 present live)
- Registration: DoraHacks: <https://dorahacks.io/hackathon/qday/detail>
- Repo: <https://github.com/qday-io> · Discord: <https://discord.gg/bYPhjmrSfK>

Everything marked **verified** below was checked against the live network or
the live site, not copied from the marketing copy.

---

## 1. What the chain actually is

| Fact | Value | How it was verified |
| --- | --- | --- |
| Chain ID | `44005` (`0xabe5`) | `cast chain-id` against the RPC |
| RPC | `https://rpc-test.qday.info` | `eth_chainId` → `0xabe5` |
| Explorer | `https://explorer-test.qday.info` | Blockscout v2 API responds |
| Block height | ~3,960,000 | `cast block-number` |
| Base fee | 7 wei | `cast block latest --field baseFeePerGas` |
| Gas limit | 30,000,000 | same |
| Consensus | PoS (empty `parentBeaconRoot`, `difficulty 0`) | block header |
| Gas currency | tQDAY | site + faucet |
| EVM version | Cancun | configured; node is Polygon CDK based |
| Solc | 0.8.35 | builds clean against forge-std |

**tUSD8**. The challenge's test stablecoin:

| Fact | Value |
| --- | --- |
| Address | `0x456569838f1d43009A91ebA4263147Afd7233483` |
| Name / symbol | `tUSD8` / `tUSD8` |
| Decimals | **6** (not 18, this will bite anyone who assumes) |
| Total supply | 3,227,400 tUSD8 |
| Bytecode | 2,995 chars, a real, live ERC-20 |

**The faucet** is at <https://faucet.qday.info>. Its `claim(address)` is
**operator-only**: calling it from any other address reverts with
`NotOperator()` (`0x7c214f04`). The web UI calls it from a funded hot wallet
(`0xD3f24278…5a1E2`) behind Cloudflare Turnstile. There is no way around the
human step. The on-chain faucet also has a contract at
`0x33d19Bde2e1798c13808f17BfBa1780b28e4bACC`.

---

## 2. What the challenge asks for

One complete stablecoin payment flow, end to end, on Aevum Testnet. Four
deliverables:

1. **Open-source code**: a public GitHub repository, clean and readable.
2. **Aevum integration**: evidence the app uses QDay infrastructure.
3. **Live deployment**: a working demo, a prototype interface, or a packaged
   Docker image that runs.
4. **Project documentation**: the problem, the architecture, the core
   workflows, the technologies used.

Tracks: Invoice Payments · Payroll and Vesting · Crowdfunding ·
Confirmation of Payee · Decentralized Payments · Digital Ownership ·
Native AI Assistants · or another business payment tool.

### How the points work

| Criterion | Points | What it rewards |
| --- | --- | --- |
| Innovation and originality | 20 | a genuinely new idea, not a clone |
| User experience and presentation | 15 | it has to feel like a product |
| Technical quality and platform integration | 15 | deep use of Aevum, not a plain ERC-20 |
| Real-world utility | 15 | a problem someone actually has |
| Safety, trust and controls | 15 | this is where security people win |
| A clear, well-structured demo | 10 | 3 to 5 minutes, live |
| Documentation | 10 | architecture, workflows, technologies |
| **Total** | **100** | |

Note the shape: **30 of the 100 points are for safety, trust and controls.**
A project that is only "pay an invoice" scores well on utility and poorly
everywhere else. A project that is "pay an invoice **under enforceable
controls**, where the interesting part is the control plane" scores across
the board.

### The rules that will disqualify a submission

- All settlement and transaction traffic must happen on **Aevum Testnet**.
  "Settlement on Base doesn't count."
- **Core building must happen during the build period** (Nov 16 to Dec 11).
  Adding tUSD8 to an existing product does not count. Boilerplate,
  scaffolding, standard libraries and templates are allowed.
- The public repository needs a **permissive licence**: MIT or Apache 2.0.
- Reused code keeps its copyright notices and licence headers, with a
  comment naming source repo, author and licence above each borrowed
  snippet, and third-party licences listed in `README.md` or a `NOTICE` file.
- At least one team member must attend the **live demo on Dec 15 at 06:00
  UTC**. A pre-recorded video cannot replace attendance.
- Only test tokens. No tokens are issued or promised.
- Solo, or a team of 2 to 4 formed before the event.

---

## 3. The project

### Working title: **Aevum Shield**: payments under enforceable policy

The pitch in one line: *an AI agent can pay for things, but it can only pay
within limits someone set in advance, and every payment is explainable
afterwards.*

The insight: stablecoins solved the *movement* of value for autonomous
software and left the *permission* problem exactly where it was. An agent
with a spending key can be talked into paying anything. There is no cap, no
allowlist, no rate limit, no pause, and no record you can hand to an
auditor.

Aevum's own framing is agent payments: x402, AA smart wallets, a stablecoin
paymaster. The gap in that story is the control plane.

### The flow

```
  merchant                policy engine (on-chain)            agent / wallet
     │                            │                                │
     │  createInvoice(payee, │                                │
     │  amount, deadline, nonce)  │                                │
     ├───────────────────────────►│                                │
     │                            │                                │
     │                            │   pay(invoiceId) via x402      │
     │                            │◄───────────────────────────────┤
     │                            │                                │
     │                            │  checks:                       │
     │                            │   · payee allowlisted?         │
     │                            │   · amount ≤ invoice amount?   │
     │                            │   · within daily budget?       │
     │                            │   · recipient match (EIP-712)? │
     │                            │   · deadline not passed?       │
     │                            │                                │
     │                            │  transfers tUSD8, emits a      │
     │                            │  PaymentSettled event with     │
     │                            │  the policy that allowed it    │
     │◄───────────────────────────┴────────────────────────────────┤
     │                            │                                │
     │  settle / dispute / refund within the window                │
```

### The three components

**1. `PolicyVault`. The control plane.**
Holds the rules a payer sets: an allowlist of payees, a per-payment cap, a
daily cap, a per-payee cap, and a global pause. Enforced on-chain at the
moment of transfer, not by the agent's good behaviour.

**2. `InvoiceEscrow`. The payment flow.**
Merchant creates an invoice bound to a payee, an amount and a deadline.
Payer funds it through the policy vault. Funds are held until the merchant
settles, or the deadline passes and the payer can reclaim. Disputes refund
without a third party, because the escrow is the counterparty.

**3. `PaymentAgent`. The agent that pays.**
An AI agent that receives an invoice, asks the policy vault whether it may
pay, and pays if it may. If it may not, it explains exactly which rule
stopped it, in words, not a stack trace. This is the "Native AI Assistants"
track and the demo's best thirty seconds.

### Why this scores

| Criterion | How the project answers it |
| --- | --- |
| Innovation (20) | The control plane is the product, not the payment. Agent payments without policy are the open problem in this exact space. |
| UX (15) | An agent that says "I can't pay this, your daily cap is 50 tUSD8 and this invoice is 120" is a better demo than a spinner. |
| Technical (15) | ERC-4337-style account abstraction, EIP-712 signed authorisations, on-chain policy evaluation, events as an audit trail, four things to get right, all on Aevum. |
| Utility (15) | Any company letting an agent spend money has this problem today and solves it with a spreadsheet and a human. |
| Safety (15) | Caps, allowlists, pause, expiry, replay protection, and a policy decision that is recorded on-chain. This is the 30-point criterion and it is the whole design. |
| Demo (10) | One flow, one screen, one failure case shown on purpose. |
| Docs (10) | The architecture *is* the documentation. |

### The failure case is the demo

Showing a payment that is **refused**. And showing the exact rule that
refused it, is worth more than showing three that succeed. It demonstrates
the safety criterion live, which is the one a video of happy paths cannot.

---

## 4. Repository layout

```
aevum-shield/
├── contracts/
│   ├── PolicyVault.sol          caps, allowlists, pause
│   ├── InvoiceEscrow.sol        invoice lifecycle, settlement, refunds
│   ├── PaymentAgent.sol         the agent-side adapter
│   └── interfaces/
├── test/                        Foundry tests
├── script/                      deploy + demo scripts
├── agent/                       the AI agent that pays (TypeScript/Python)
├── app/                         the demo UI
├── docs/                        architecture, decisions, threat model
├── README.md
├── NOTICE
└── LICENSE                      MIT
```

---

## 5. Timeline

Today is **24 November**. That leaves **17 days**.

| Date | Milestone |
| --- | --- |
| Nov 24 | Repo, toolchain, network verified. Contracts sketched. |
| Nov 25 to 26 | `PolicyVault` + `InvoiceEscrow` written and tested locally. |
| Nov 27 | Agent adapter + demo UI skeleton. |
| Nov 28 | Local end-to-end against anvil. |
| Nov 29 to 30 | Deploy to Aevum. Real tUSD8 flow. **Hard checkpoint.** |
| Dec 1 to 4 | Hardening, edge cases, the refusal path, events, documentation. |
| Dec 5 to 7 | Demo polish. Architecture doc. Screencast. |
| Dec 8 | **Full dress rehearsal.** Deploy from a clean checkout. |
| Dec 9 | Buffer. Fix what the rehearsal broke. |
| Dec 10 | Submission written. Repo public. |
| **Dec 11, 08:00 UTC** | **Submission closes.** Do not rely on the last hour. |

The Demo Day is **Dec 15**, four days after submission. So the demo must
be recorded and rehearsed *before* the submission closes, not after.

---

## 6. Open questions

1. **Does Aevum have a working x402 facilitator?** The site says x402 is
   live. If there is a facilitator URL and a documented flow, the agent pays
   through x402 and the project is unmistakably an Aevum project. If not, the
   agent pays directly through the escrow and the x402 story is dropped.
2. **Is there an AA smart wallet to use, or do we deploy our own?** The site
   says "AA smart wallet support are live". If a canonical wallet exists,
   use it. That is platform integration. If not, deploying one is more work
   but more of our own code to show.
3. **What is the stablecoin paymaster, and is it usable?** If tUSD8 gas
   sponsorship works, an agent can pay *and* pay its own gas, which is the
   whole agentic-payment story.
4. **DoraHacks submission form**: what exactly is required: repo URL,
   deployed contract addresses, a video, a writeup? What is the field list?
5. **Is the AA wallet / x402 code audited?** If we are building on it, the
   review is part of the documentation.

---

## 7. What is already done

- [x] Foundry project pointed at Aevum; builds clean.
- [x] Network verified end to end: chain ID, RPC, explorer, block production.
- [x] tUSD8 verified live on-chain: address, name, decimals, supply.
- [x] Faucet reverse-engineered: `claim(address)` is operator-only.
- [x] Project deployer key generated, backed up outside the repo.
- [x] Repo initialised, `.gitignore` and `.env.example` in place.
- [ ] Funding the deployer address (needs the Cloudflare check).
- [ ] DoraHacks registration.
