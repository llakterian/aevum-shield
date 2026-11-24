// SPDX-License-Identifier: MIT
//
// Aevum Shield — the demonstration server.
//
// It reads the payer's policy straight off the chain and shows what it
// says. There is no database and no cache of the rules: every number on
// the screen is a contract call, so the demo cannot drift away from the
// truth it is supposed to be demonstrating.
//
// The one thing it can do that a viewer cannot is ask the agent to try to
// pay, and the one thing a viewer can do that it cannot is flip the
// pause. The pause is the kill switch, so it gets its own button.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPublicClient, createWalletClient, http, formatUnits, decodeEventLog } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const here = dirname(fileURLToPath(import.meta.url));

/* ------------------------------------------------------------------ *
 * Configuration
 * ------------------------------------------------------------------ */

const config = {
  rpcUrl: process.env.AEVUM_RPC_URL ?? 'https://rpc-test.qday.info',
  chainId: Number(process.env.AEVUM_CHAIN_ID ?? 44005),
  token: process.env.TUSD8 ?? '0x456569838f1d43009A91ebA4263147Afd7233483',
  policy: process.env.POLICY ?? '',
  escrow: process.env.ESCROW ?? '',
  agent: process.env.AGENT ?? '',
  merchant: process.env.MERCHANT ?? '',
  payee: process.env.PAYEE ?? '',
  // The payer's key. Only the pause needs it: paying goes through the
  // agent contract, which anyone may call, because the policy is what
  // actually authorises a payment.
  payerKey: process.env.DEPLOYER_PRIVATE_KEY ?? '',
  port: Number(process.env.PORT ?? 8080),
};

/* ------------------------------------------------------------------ *
 * Chain
 * ------------------------------------------------------------------ */

const abi = {
  PayPolicy: JSON.parse(await readFile(join(here, 'abi/PayPolicy.json'), 'utf8')),
  InvoiceEscrow: JSON.parse(await readFile(join(here, 'abi/InvoiceEscrow.json'), 'utf8')),
  PaymentAgent: JSON.parse(await readFile(join(here, 'abi/PaymentAgent.json'), 'utf8')),
  ERC20: JSON.parse(await readFile(join(here, 'abi/ERC20.json'), 'utf8')),
};

const publicClient = createPublicClient({
  transport: http(config.rpcUrl, { timeout: 20_000 }),
  chain: { id: config.chainId, name: 'Aevum Testnet', nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 }, rpcUrls: { default: { http: [config.rpcUrl] } } },
});

let walletClient = null;
let payerAccount = null;
if (config.payerKey) {
  payerAccount = privateKeyToAccount(config.payerKey);
  walletClient = createWalletClient({
    account: payerAccount,
    transport: http(config.rpcUrl, { timeout: 20_000 }),
    chain: { id: config.chainId, name: 'Aevum Testnet', nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 }, rpcUrls: { default: { http: [config.rpcUrl] } } },
  });
}

/* ------------------------------------------------------------------ *
 * Reading the policy
 * ------------------------------------------------------------------ */

// The Decision enum, in the order the contract declares it.
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

// A refusal explained in the user's terms rather than the contract's.
const EXPLAIN = {
  allowed: 'Every rule passed — the payee is allowed, the caps have room, and payments are not paused.',
  'escrow-not-trusted': 'That merchant is not on the trusted list.',
  'invoice-unknown': 'That invoice does not exist.',
  'invoice-already-paid': 'That invoice has already been paid.',
  'invoice-expired': 'That invoice has expired.',
  'payee-not-allowed': 'That payee is not on the allowed list.',
  'per-payment-cap-exceeded': 'That invoice is above the single-payment cap.',
  'per-payee-cap-exceeded': 'That invoice is above the cap for that payee today.',
  'daily-cap-exceeded': 'That invoice is above the daily cap.',
  'operator-cap-exceeded': 'That invoice is above the agent’s own daily cap.',
  paused: 'Payments are paused.',
  'already-approved': 'That invoice has already been approved.',
};

function short(address) {
  if (!address) return '—';
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

async function readPolicy() {
  const [owner, paused, perPaymentCap, perPayeeCap, dailyCap, dailySpent, balance, decimals, symbol] =
    await Promise.all([
      publicClient.readContract({ address: config.policy, abi: abi.PayPolicy, functionName: 'owner' }),
      publicClient.readContract({ address: config.policy, abi: abi.PayPolicy, functionName: 'paused' }),
      publicClient.readContract({ address: config.policy, abi: abi.PayPolicy, functionName: 'perPaymentCap' }),
      publicClient.readContract({ address: config.policy, abi: abi.PayPolicy, functionName: 'perPayeeCap' }),
      publicClient.readContract({ address: config.policy, abi: abi.PayPolicy, functionName: 'dailyCap' }),
      publicClient.readContract({ address: config.policy, abi: abi.PayPolicy, functionName: 'dailySpent' }),
      publicClient.readContract({ address: config.token, abi: abi.ERC20, functionName: 'balanceOf', args: [config.policy] }),
      publicClient.readContract({ address: config.token, abi: abi.ERC20, functionName: 'decimals' }),
      publicClient.readContract({ address: config.token, abi: abi.ERC20, functionName: 'symbol' }),
    ]);

  const d = Number(decimals);
  cachedDecimals = d;
  const fmt = (v) => Number(formatUnits(v, d));

  // The allowlist. The contract exposes the flags as public mappings, so
  // the honest way to build the list is to ask the chain which payees are
  // known at all. The escrow's invoice list gives us the candidates.
  const invoiceCount = await publicClient.readContract({
    address: config.escrow,
    abi: abi.InvoiceEscrow,
    functionName: 'invoiceCount',
  });

  const payees = new Set();
  const invoices = [];
  for (let i = 0n; i < invoiceCount && i < 25n; i++) {
    const id = await publicClient.readContract({
      address: config.escrow,
      abi: abi.InvoiceEscrow,
      functionName: 'invoiceIdAt',
      args: [i],
    });
    const details = await publicClient.readContract({
      address: config.escrow,
      abi: abi.InvoiceEscrow,
      functionName: 'invoiceDetails',
      args: [id],
    });
    const status = await publicClient.readContract({
      address: config.escrow,
      abi: abi.InvoiceEscrow,
      functionName: 'statusOf',
      args: [id],
    });
    const [payee, amount, deadline, paidIn] = details;
    payees.add(payee);
    invoices.push({
      id,
      payee,
      amount: fmt(amount),
      amountRaw: amount.toString(),
      deadline: Number(deadline),
      paidIn,
      status: ['none', 'created', 'paid', 'settled', 'refunded'][Number(status)],
    });
  }

  const allowlist = [];
  for (const payee of payees) {
    const allowed = await publicClient.readContract({
      address: config.policy,
      abi: abi.PayPolicy,
      functionName: 'payeeAllowed',
      args: [payee],
    });
    allowlist.push({ address: payee, allowed });
  }

  const agentAllowed = await publicClient.readContract({
    address: config.policy,
    abi: abi.PayPolicy,
    functionName: 'operatorAllowed',
    args: [config.agent],
  });

  const remaining = dailyCap === 0n ? null : fmt(dailyCap - dailySpent);

  return {
    chain: { id: config.chainId, name: 'Aevum Testnet', rpc: config.rpcUrl },
    token: { address: config.token, symbol, decimals: d },
    contracts: { policy: config.policy, escrow: config.escrow, agent: config.agent },
    policy: {
      owner,
      paused,
      perPaymentCap: fmt(perPaymentCap),
      perPayeeCap: fmt(perPayeeCap),
      dailyCap: fmt(dailyCap),
      dailySpent: fmt(dailySpent),
      dailyRemaining: remaining,
      balance: fmt(balance),
      agentAllowed,
    },
    payees: allowlist,
    invoices: invoices.reverse(),
    events: await readEvents(),
  };
}

/**
 * Read the audit trail straight from the chain.
 *
 * The events are the record. There is no log file and no database, so the
 * trail cannot be edited without editing the chain, and it can be checked
 * against the contract's own state by anyone.
 *
 * Aevum limits `eth_getLogs` to 1,000 blocks per call, so the window is
 * walked in chunks and the two contracts are read in a single query each.
 */
async function readEvents() {
  const fromBlock = process.env.EVENTS_FROM_BLOCK
    ? BigInt(process.env.EVENTS_FROM_BLOCK)
    : undefined;
  const toBlock = 'latest';

  const head = await publicClient.getBlockNumber();
  const start = fromBlock ?? (head > 1000n ? head - 1000n : 0n);
  const end = toBlock === 'latest' ? head : BigInt(toBlock);

  // Every event from both contracts, in one ABI so the logs can be
  // decoded without knowing which contract emitted them.
  const eventsAbi = [...abi.PayPolicy, ...abi.InvoiceEscrow].filter((x) => x.type === 'event');

  const logs = [];
  const CHUNK = 1000n;
  for (let from = start; from <= end; from += CHUNK) {
    const to = from + CHUNK - 1n > end ? end : from + CHUNK - 1n;
    const chunk = await publicClient
      .getLogs({ address: [config.policy, config.escrow], fromBlock: from, toBlock: to })
      .catch(() => []);
    logs.push(...chunk);
  }

  const rows = [];

  for (const log of logs) {
    let decoded;
    try {
      decoded = decodeEventLog({ abi: eventsAbi, data: log.data, topics: log.topics, strict: false });
    } catch {
      continue;
    }
    const name = decoded.eventName;
    const args = decoded.args;

    const base = { block: Number(log.blockNumber), tx: log.transactionHash };
    const amount = args.amount === undefined ? undefined : Number(formatUnits(args.amount, stateDecimals()));

    switch (name) {
      case 'InvoiceCreated':
        rows.push({ ...base, kind: 'created', what: `Invoice for ${short(args.payee)}`, amount });
        break;
      case 'InvoicePaid':
        rows.push({ ...base, kind: 'paid', what: 'Paid', amount });
        break;
      case 'InvoiceSettled':
        rows.push({ ...base, kind: 'settled', what: `Settled to ${short(args.payee)}`, amount });
        break;
      case 'InvoiceRefunded':
        rows.push({ ...base, kind: 'refunded', what: 'Refunded to the payer', amount });
        break;
      case 'ReservationMade':
        rows.push({ ...base, kind: 'reserved', what: `Reserved for ${short(args.payee)}`, amount });
        break;
      case 'PaymentPulled':
        rows.push({ ...base, kind: 'pulled', what: `Money moved to ${short(args.escrow)}`, amount });
        break;
      case 'ReservationReleased':
        rows.push({ ...base, kind: 'released', what: 'Reservation released, budget returned', amount });
        break;
      case 'DecisionRecorded': {
        const key = DECISIONS[Number(args.decision)] ?? 'unknown';
        rows.push({
          ...base,
          kind: key === 'allowed' ? 'allowed' : 'refused',
          what: key === 'allowed' ? 'Policy allowed the payment' : 'Policy refused the payment',
          why: key === 'allowed' ? 'every rule passed' : args.reason,
        });
        break;
      }
      default:
        break;
    }
  }

  rows.sort((a, b) => b.block - a.block);

  // One pass to read the timestamps of the blocks we are showing. The
  // client caches block data, so repeated polls are cheap.
  const blocks = [...new Set(rows.map((r) => r.block))].slice(0, 40);
  const times = new Map();
  await Promise.all(
    blocks.map(async (b) => {
      try {
        const block = await publicClient.getBlock({ blockNumber: BigInt(b) });
        times.set(String(b), Number(block.timestamp));
      } catch {
        times.set(String(b), 0);
      }
    }),
  );
  for (const row of rows) row.timestamp = times.get(String(row.block)) ?? 0;

  return rows.slice(0, 40);
}

let cachedDecimals = 6;
function stateDecimals() {
  return cachedDecimals;
}

/**
 * Ask the policy what would happen, without doing it.
 *
 * This is the call that makes a refusal explainable. The agent never has
 * to guess why it was stopped; it asks, and the contract answers in a
 * sentence.
 */
async function askPolicy(invoiceId) {
  const [decision, reason] = await publicClient.readContract({
    address: config.policy,
    abi: abi.PayPolicy,
    functionName: 'check',
    args: [config.escrow, invoiceId, config.agent],
  });
  const key = DECISIONS[Number(decision)];
  return {
    allowed: Number(decision) === 0,
    decision: key,
    reason,
    explanation: EXPLAIN[key] ?? reason,
  };
}

/* ------------------------------------------------------------------ *
 * Actions
 * ------------------------------------------------------------------ */

async function agentPays(invoiceId) {
  const decision = await askPolicy(invoiceId);
  if (!decision.allowed) {
    // The agent refuses in words. It does not throw — a sentence is a
    // better answer than a stack trace.
    return { paid: false, ...decision };
  }
  const hash = await walletClient.writeContract({
    address: config.agent,
    abi: abi.PaymentAgent,
    functionName: 'pay',
    args: [config.escrow, invoiceId],
    account: payerAccount,
    chain: { id: config.chainId, name: 'Aevum Testnet', nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 }, rpcUrls: { default: { http: [config.rpcUrl] } } },
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
  return {
    paid: true,
    ...decision,
    txHash: hash,
    block: Number(receipt.blockNumber),
    gasUsed: Number(receipt.gasUsed),
  };
}

async function setPaused(paused) {
  const hash = await walletClient.writeContract({
    address: config.policy,
    abi: abi.PayPolicy,
    functionName: 'setPaused',
    args: [paused],
    account: payerAccount,
    chain: { id: config.chainId, name: 'Aevum Testnet', nativeCurrency: { name: 'tQDAY', symbol: 'tQDAY', decimals: 18 }, rpcUrls: { default: { http: [config.rpcUrl] } } },
  });
  await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
  return { paused, txHash: hash };
}

/* ------------------------------------------------------------------ *
 * HTTP
 * ------------------------------------------------------------------ */

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};

function json(res, code, body) {
  const payload = JSON.stringify(body);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(payload) });
  res.end(payload);
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    return {};
  }
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`);
  const path = url.pathname;

  try {
    if (path === '/api/state') {
      return json(res, 200, await readPolicy());
    }

    if (path === '/api/decide' && req.method === 'POST') {
      const { invoiceId } = await readBody(req);
      if (!invoiceId) return json(res, 400, { error: 'invoiceId is required' });
      return json(res, 200, await askPolicy(invoiceId));
    }

    if (path === '/api/pay' && req.method === 'POST') {
      const { invoiceId } = await readBody(req);
      if (!invoiceId) return json(res, 400, { error: 'invoiceId is required' });
      if (!walletClient) return json(res, 503, { error: 'no signing key configured' });
      return json(res, 200, await agentPays(invoiceId));
    }

    if (path === '/api/pause' && req.method === 'POST') {
      const { paused } = await readBody(req);
      if (!walletClient) return json(res, 503, { error: 'no signing key configured' });
      return json(res, 200, await setPaused(Boolean(paused)));
    }

    // Static files.
    const name = path === '/' ? 'index.html' : path.replace(/^\/+/, '');
    const file = join(here, 'public', name);
    if (!file.startsWith(join(here, 'public'))) {
      res.writeHead(403).end('forbidden');
      return;
    }
    const data = await readFile(file);
    const ext = name.slice(name.lastIndexOf('.'));
    res.writeHead(200, { 'content-type': MIME[ext] ?? 'application/octet-stream' });
    res.end(data);
  } catch (err) {
    if (err.code === 'ENOENT') {
      res.writeHead(404).end('not found');
      return;
    }
    json(res, 500, { error: err.shortMessage ?? err.message });
  }
});

server.listen(config.port, () => {
  console.log(`Aevum Shield demo on http://localhost:${config.port}`);
  console.log(`  chain   ${config.chainId} (${config.rpcUrl})`);
  console.log(`  policy  ${config.policy}`);
  console.log(`  escrow  ${config.escrow}`);
  console.log(`  agent   ${config.agent}`);
  if (!config.policy || !config.escrow || !config.agent) {
    console.warn('  WARNING: POLICY, ESCROW and AGENT must be set. Run the deploy script first.');
  }
});
