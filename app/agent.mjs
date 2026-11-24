// SPDX-License-Identifier: MIT
//
// Aevum Shield — the agent adapter.
//
// The point of this project is that an agent cannot be trusted with money.
// This file is where that claim gets tested. It runs a series of attacks
// against the deployed policy — every one of them is a real call or a
// real transaction against the real contract — and reports what the
// contract said.
//
// There is no mock policy here and no simulated refusal. Each attempt is
// either accepted by the chain or rejected by it, and the reason printed
// is the contract's own.
//
//   node agent.mjs              # run every attempt
//   node agent.mjs --verbose    # include the transaction hashes
//
// Exit code is 0 when the policy behaved as expected and 1 when it did
// not, so it can be used as a check.

import { createPublicClient, createWalletClient, http, formatUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

const config = {
  rpcUrl: process.env.AEVUM_RPC_URL ?? 'http://127.0.0.1:8545',
  chainId: Number(process.env.AEVUM_CHAIN_ID ?? 44005),
  token: process.env.TUSD8 ?? '',
  policy: process.env.POLICY ?? '',
  escrow: process.env.ESCROW ?? '',
  agent: process.env.AGENT ?? '',
  merchant: process.env.MERCHANT ?? '',
  payee: process.env.PAYEE ?? '',
  // The payer's key. The payer owns the policy and sets the rules. The
  // harness never uses it to attack the policy — an attack signed by the
  // owner is not an attack.
  payerKey: process.env.DEPLOYER_PRIVATE_KEY ?? '',
  // The agent's key. This is the compromised party: it is a registered
  // operator, so it may ask the policy to pay, and it is not the owner,
  // so it may not change the rules.
  agentKey: process.env.AGENT_PRIVATE_KEY ?? '',
  // The merchant's key. The merchant writes invoices, so the harness can
  // create the exact invoices it needs to test against.
  merchantKey: process.env.MERCHANT_PRIVATE_KEY ?? '',
  verbose: process.argv.includes('--verbose'),
};

const abi = {
  PayPolicy: JSON.parse(await readFile(join(here, 'abi/PayPolicy.json'), 'utf8')),
  InvoiceEscrow: JSON.parse(await readFile(join(here, 'abi/InvoiceEscrow.json'), 'utf8')),
  PaymentAgent: JSON.parse(await readFile(join(here, 'abi/PaymentAgent.json'), 'utf8')),
  ERC20: JSON.parse(await readFile(join(here, 'abi/ERC20.json'), 'utf8')),
};

const chain = {
  id: config.chainId,
  name: 'Aevum Testnet',
  nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 },
  rpcUrls: { default: { http: [config.rpcUrl] } },
};

const publicClient = createPublicClient({ transport: http(config.rpcUrl, { timeout: 20_000 }), chain });

/**
 * A signer for one of the three roles.
 *
 * The harness signs as the agent, never as the payer. If the agent held
 * the payer's key there would be nothing to test: the owner is allowed to
 * change its own rules.
 */
function signerFor(key) {
  if (!key) return null;
  const account = privateKeyToAccount(key);
  return {
    account,
    client: createWalletClient({ account, transport: http(config.rpcUrl, { timeout: 20_000 }), chain }),
  };
}

const agentSigner = signerFor(config.agentKey);
const merchantSigner = signerFor(config.merchantKey);

const DECISIONS = [
  'allowed',
  'escrow-not-trusted',
  'invoice-unknown',
  'invoice-already-paid',
  'invoice-expired',
  'payee-not-allowed',
  'per-payment-cap-exceeded',
  'per-payee-cap-exceeded',
  'daily-cap-exceeded',
  'operator-cap-exceeded',
  'paused',
  'already-approved',
];

// ── output ──────────────────────────────────────────────────────────

const useColour = process.stdout.isTTY && !process.env.NO_COLOR;
const paint = (code, text) => (useColour ? `[${code}m${text}[0m` : text);
const green = (t) => paint('32', t);
const red = (t) => paint('31', t);
const dim = (t) => paint('2', t);
const bold = (t) => paint('1', t);

const results = [];

function record(attempt) {
  results.push(attempt);
  const mark = attempt.passed ? green('  PASS ') : red('  FAIL ');
  console.log(`${mark} ${attempt.name}`);
  console.log(`         ${attempt.detail}`);
  if (config.verbose && attempt.txHash) console.log(dim(`         tx ${attempt.txHash}`));
}

/**
 * Ask the policy a question without doing anything.
 *
 * Returns the decision and the reason the contract gives.
 */
async function ask(escrow, invoiceId, operator) {
  const [decision, reason] = await publicClient.readContract({
    address: config.policy,
    abi: abi.PayPolicy,
    functionName: 'check',
    args: [escrow, invoiceId, operator ?? config.agent],
  });
  return { decision: DECISIONS[Number(decision)], reason };
}

/**
 * Send a transaction and report what the chain said.
 *
 * A revert is a result, not an exception: the refusal is the thing being
 * tested, so it is read out of the error rather than thrown away.
 */
async function send(label, signer = agentSigner) {
  if (!signer) {
    return { ok: false, error: 'no signing key configured' };
  }
  try {
    const hash = await signer.client.writeContract({
      address: label.address,
      abi: label.abi,
      functionName: label.functionName,
      args: label.args ?? [],
      account: signer.account,
      chain,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
    if (receipt.status === 'success') return { ok: true, hash };
    return { ok: false, hash, error: 'the transaction reverted' };
  } catch (err) {
    return { ok: false, error: shortReason(err) };
  }
}

/** Pull the useful part out of a revert. */
function shortReason(err) {
  // viem decodes a custom error onto the cause, which is far more useful
  // than "the transaction reverted".
  for (const candidate of [err?.cause?.data, err?.data, err?.cause?.cause?.data]) {
    if (candidate && typeof candidate === 'object' && candidate.errorName) {
      const args = Array.isArray(candidate.args) && candidate.args.length
        ? ` (${candidate.args.map((a) => String(a)).join(', ')})`
        : '';
      return `${candidate.errorName}${args}`;
    }
  }

  const text = err?.message ?? err?.shortMessage ?? String(err);
  // The rendered contract call includes the decoded error in the body.
  const rendered = text.match(/Error:\s+([A-Z][A-Za-z0-9_]+)\s*\(/);
  if (rendered) return rendered[1];
  const quoted = text.match(/'([^']+)'/);
  if (quoted) return quoted[1];
  return (err?.shortMessage ?? text.split('\n')[0]).slice(0, 120);
}

// ── the attempts ────────────────────────────────────────────────────

/**
 * The merchant writes a fresh invoice and the harness reads its id back
 * from the chain.
 *
 * The id is not guessed. It is a hash of the invoice's terms and the
 * escrow's nonce, and it is read from the contract after the transaction
 * rather than computed, so the harness always attacks a real invoice.
 */
async function createInvoice(payee, amountUnits) {
  const before = Number(
    await publicClient.readContract({
      address: config.escrow,
      abi: abi.InvoiceEscrow,
      functionName: 'invoiceCount',
    }),
  );

  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const result = await send(
    {
      address: config.escrow,
      abi: abi.InvoiceEscrow,
      functionName: 'createInvoice',
      args: [payee, amountUnits, deadline],
    },
    merchantSigner,
  );
  if (!result.ok) return { ok: false, error: result.error };

  const after = Number(
    await publicClient.readContract({
      address: config.escrow,
      abi: abi.InvoiceEscrow,
      functionName: 'invoiceCount',
    }),
  );
  const id = await publicClient.readContract({
    address: config.escrow,
    abi: abi.InvoiceEscrow,
    functionName: 'invoiceIdAt',
    args: [BigInt(after - 1)],
  });
  return { ok: true, id, hash: result.hash, index: after - 1, before };
}

// ── the attempts ────────────────────────────────────────────────────

/**
 * Each attempt is a thing an agent might try, and the answer the policy
 * is expected to give.
 */
async function runAttempts() {
  const attempts = [];

  // A payee that is deliberately not on the allowlist.
  const stranger = '0x000000000000000000000000000000000000dEaD';
  // A second escrow the payer has never approved.
  const hostileEscrow = '0x000000000000000000000000000000000000dEaD';

  const decimals = Number(
    await publicClient.readContract({
      address: config.token,
      abi: abi.ERC20,
      functionName: 'decimals',
    }),
  );
  const unit = 10n ** BigInt(decimals);
  const allowedPayee = config.payee || '0x5Ec280C6196cc3669e88FED0c1185920302bD0ED';

  // How much the agent can still spend today.
  //
  // The harness spends real budget, so it has to ask first. Asking is
  // also the point: the agent's own remaining budget is a number the
  // policy will not let it exceed, so the harness sizes its test to fit
  // inside it. A second run against the same deployment therefore still
  // works — it just tests with whatever is left.
  const agentAddress = agentSigner ? agentSigner.account.address : config.agent;
  const [perPaymentCap, dailyRemaining, operatorRemaining, perPayeeRemaining] = await Promise.all([
    publicClient.readContract({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'perPaymentCap',
    }),
    publicClient.readContract({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'dailyRemaining',
    }),
    publicClient.readContract({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'operatorRemaining',
      args: [agentAddress],
    }),
    publicClient.readContract({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'perPayeeRemaining',
      args: [allowedPayee],
    }),
  ]);

  // A cap of zero means "no limit" in this contract, so it is skipped.
  const limits = [perPaymentCap, dailyRemaining, operatorRemaining, perPayeeRemaining].filter(
    (v) => v > 0n,
  );
  const usable = limits.length === 0 ? 25n * unit : limits.reduce((a, b) => (a < b ? a : b));
  const budget = usable < 25n * unit ? usable : 25n * unit;

  if (budget === 0n) {
    console.log(red('  The agent has no budget left for today. The policy has nothing to spare it.'));
    console.log();
    process.exit(1);
  }

  console.log(dim(`  the agent may spend ${formatUnits(budget, decimals)} more today`));

  // 1. The ordinary case. The agent asks to pay an invoice that is within
  //    every rule. The policy should allow it.
  {
    const invoice = await createInvoice(allowedPayee, budget);
    const verdict = await ask(config.escrow, invoice.id);
    attempts.push({
      name: 'Pay an invoice that breaks no rule',
      expectation: 'the policy allows it',
      passed: verdict.decision === 'allowed',
      detail: `the policy said: ${verdict.reason}`,
      txHash: invoice.hash,
    });
  }

  // 2. The amount is too big. The agent may be confused, or compromised.
  {
    const invoice = await createInvoice(allowedPayee, 500n * unit);
    const verdict = await ask(config.escrow, invoice.id);
    attempts.push({
      name: 'Pay an invoice above the single-payment cap',
      expectation: 'the policy refuses it',
      passed: verdict.decision === 'per-payment-cap-exceeded',
      detail: `the policy said: ${verdict.reason}`,
      txHash: invoice.hash,
    });
  }

  // 3. The payee is not on the allowlist.
  {
    const invoice = await createInvoice(stranger, 25n * unit);
    const verdict = await ask(config.escrow, invoice.id);
    attempts.push({
      name: 'Pay an invoice to a payee that is not allowed',
      expectation: 'the policy refuses it',
      passed: verdict.decision === 'payee-not-allowed',
      detail: `the policy said: ${verdict.reason}`,
      txHash: invoice.hash,
    });
  }

  // 4. The agent tries a different merchant's escrow — one the payer has
  //    never approved. The policy must refuse before it reads anything
  //    from that escrow.
  {
    const invoice = await createInvoice(allowedPayee, 25n * unit);
    const verdict = await ask(hostileEscrow, invoice.id);
    attempts.push({
      name: 'Pay through an escrow that is not on the trusted list',
      expectation: 'the policy refuses it',
      passed: verdict.decision === 'escrow-not-trusted',
      detail: `the policy said: ${verdict.reason}`,
      txHash: invoice.hash,
    });
  }

  // 5. The agent approves an invoice for real, then tries to approve it
  //    again, hoping the second approval spends the budget twice.
  {
    const invoice = await createInvoice(allowedPayee, budget);

    const before = await publicClient.readContract({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'dailySpent',
    });

    const first = await send({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'approve',
      args: [config.escrow, invoice.id],
    });

    const second = await send({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'approve',
      args: [config.escrow, invoice.id],
    });

    const spent = await publicClient.readContract({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'dailySpent',
    });
    const charged = spent - before;

    attempts.push({
      name: 'Approve the same invoice twice',
      expectation: 'the second approval is refused and the budget is charged once',
      passed: first.ok && !second.ok && charged === budget,
      detail: !second.ok
        ? `the chain refused it: ${second.error} — the budget was charged ${formatUnits(charged, decimals)}, once`
        : `THE SECOND APPROVAL WENT THROUGH — the budget was spent twice (${formatUnits(charged, decimals)} charged)`,
      txHash: second.hash,
    });

    // 6. And now that it is approved, the money may be pulled — exactly
    //    once, and exactly the approved amount.
    {
      const balanceBefore = await publicClient.readContract({
        address: config.token,
        abi: abi.ERC20,
        functionName: 'balanceOf',
        args: [config.escrow],
      });
      const paid = await send({
        address: config.escrow,
        abi: abi.InvoiceEscrow,
        functionName: 'pay',
        args: [invoice.id, config.policy],
      });
      const balanceAfter = await publicClient.readContract({
        address: config.token,
        abi: abi.ERC20,
        functionName: 'balanceOf',
        args: [config.escrow],
      });
      const moved = balanceAfter - balanceBefore;

      attempts.push({
        name: 'Pull the money for an approved invoice',
        expectation: 'exactly the approved amount moves',
        passed: paid.ok && moved === budget,
        detail: paid.ok
          ? `the escrow received ${formatUnits(moved, decimals)} — the approved amount, no more`
          : `the chain refused it: ${paid.error}`,
        txHash: paid.hash,
      });

      // 7. And a second pull must fail: the authorisation is spent.
      const again = await send({
        address: config.escrow,
        abi: abi.InvoiceEscrow,
        functionName: 'pay',
        args: [invoice.id, config.policy],
      });
      attempts.push({
        name: 'Pull the same payment a second time',
        expectation: 'the chain refuses it',
        passed: !again.ok,
        detail: again.ok
          ? 'THE MONEY MOVED TWICE — the policy has a hole in it'
          : `the chain refused it: ${again.error}`,
        txHash: again.hash,
      });
    }
  }

  // 8. The agent tries to widen its own limits.
  {
    const result = await send({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'setCaps',
      args: [10n ** 18n, 10n ** 18n, 10n ** 18n],
    });
    attempts.push({
      name: 'Raise its own spending caps',
      expectation: 'the chain refuses it',
      passed: !result.ok,
      detail: result.ok
        ? 'THE CAPS WERE CHANGED — the policy has a hole in it'
        : `the chain refused it: ${result.error}`,
      txHash: result.hash,
    });
  }

  // 9. The agent tries to allow itself a new payee.
  {
    const result = await send({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'setPayee',
      args: [stranger, true],
    });
    attempts.push({
      name: 'Add a payee to the allowlist',
      expectation: 'the chain refuses it',
      passed: !result.ok,
      detail: result.ok
        ? 'THE ALLOWLIST WAS CHANGED — the policy has a hole in it'
        : `the chain refused it: ${result.error}`,
      txHash: result.hash,
    });
  }

  // 10. The agent tries to take ownership of the policy.
  {
    const result = await send({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'transferOwnership',
      args: [config.agent],
    });
    attempts.push({
      name: 'Take ownership of the policy',
      expectation: 'the chain refuses it',
      passed: !result.ok,
      detail: result.ok
        ? 'OWNERSHIP CHANGED — the policy has a hole in it'
        : `the chain refused it: ${result.error}`,
      txHash: result.hash,
    });
  }

  // 11. The agent tries to move the payer's money without an invoice.
  {
    const result = await send({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'recover',
      args: [config.token, config.agent, 1n],
    });
    attempts.push({
      name: 'Sweep the payer’s funds to itself',
      expectation: 'the chain refuses it',
      passed: !result.ok,
      detail: result.ok
        ? 'THE FUNDS MOVED — the policy has a hole in it'
        : `the chain refused it: ${result.error}`,
      txHash: result.hash,
    });
  }

  // 12. The agent tries to register itself as a trusted escrow.
  {
    const result = await send({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'setEscrow',
      args: [hostileEscrow, true],
    });
    attempts.push({
      name: 'Trust a new escrow',
      expectation: 'the chain refuses it',
      passed: !result.ok,
      detail: result.ok
        ? 'THE ESCROW WAS TRUSTED — the policy has a hole in it'
        : `the chain refused it: ${result.error}`,
      txHash: result.hash,
    });
  }

  return attempts;
}

// ── main ────────────────────────────────────────────────────────────

if (!config.policy || !config.escrow || !config.agent) {
  console.error('POLICY, ESCROW and AGENT must be set. Run script/local-up.sh first.');
  process.exit(2);
}

console.log();
console.log(bold('Aevum Shield — what happens when the agent tries'));
console.log(dim(`  policy ${config.policy}`));
console.log(dim(`  escrow ${config.escrow}`));
console.log(dim(`  agent  ${config.agent}`));
console.log(dim(`  chain  ${config.chainId} via ${config.rpcUrl}`));
console.log();

const attempts = await runAttempts();

for (const attempt of attempts) {
  record(attempt);
}

const failed = results.filter((r) => !r.passed);
console.log();
if (failed.length === 0) {
  console.log(green(bold(`  ${results.length} of ${results.length} attempts behaved as the policy promises.`)));
} else {
  console.log(red(bold(`  ${failed.length} of ${results.length} attempts did not behave as the policy promises.`)));
  for (const f of failed) console.log(red(`    - ${f.name}: expected ${f.expectation}`));
}
console.log();

process.exit(failed.length === 0 ? 0 : 1);
