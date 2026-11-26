// SPDX-License-Identifier: MIT
//
// Aevum Shield. The demonstration client.
//
// It polls the chain for the policy's state and asks the server what the
// agent would decide. Nothing here decides anything: the verdicts come
// from the policy contract, and the pay button asks the agent contract to
// try. The browser is a viewer, not a decision-maker.

const $ = (id) => document.getElementById(id);

let state = null;
let selectedInvoice = null;
let busy = false;

/* ── Formatting ──────────────────────────────────────────────── */

const short = (a) => (!a || a === '0x') ? '-' : `${a.slice(0, 6)}…${a.slice(-4)}`;

function units(value, decimals) {
  if (value === null || value === undefined) return '-';
  const n = Number(value);
  const d = decimals ?? state?.token?.decimals ?? 6;
  const text = n.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: d });
  return `${text} ${state?.token?.symbol ?? 'tUSD8'}`;
}

function ago(timestamp) {
  if (!timestamp) return '';
  const seconds = Math.floor(Date.now() / 1000 - Number(timestamp));
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

/* ── Rendering ───────────────────────────────────────────────── */

function renderPolicy() {
  const p = state.policy;
  const decimals = state.token.decimals;

  $('chainName').textContent = `${state.chain.name} · chain ${state.chain.id}`;
  $('chainBadge').title = state.chain.rpc;

  // The contracts the numbers came from. A viewer should be able to check
  // any of them on the explorer without hunting through the README.
  const c = state.contracts;
  $('footerContracts').textContent =
    `policy ${short(c.policy)} · escrow ${short(c.escrow)} · agent ${short(c.agent)}`;

  $('spent').textContent = units(p.dailySpent, decimals);
  $('cap').textContent = units(p.dailyCap, decimals);
  $('remaining').textContent = units(p.dailyRemaining, decimals);

  const ratio = p.dailyCap > 0 ? Math.min(1, p.dailySpent / p.dailyCap) : 0;
  const fill = $('meterFill');
  fill.style.width = `${ratio * 100}%`;
  fill.classList.toggle('warn', ratio >= 0.66 && ratio < 1);
  fill.classList.toggle('over', ratio >= 1);
  fill.parentElement.setAttribute('aria-valuenow', String(Math.round(ratio * 100)));

  $('perPaymentCap').textContent = units(p.perPaymentCap, decimals);
  $('perPayeeCap').textContent = units(p.perPayeeCap, decimals);
  $('balance').textContent = units(p.balance, decimals);

  const pause = $('pauseButton');
  pause.setAttribute('aria-pressed', String(p.paused));
  $('pauseLabel').textContent = p.paused ? 'Payments are paused' : 'Pause payments';

  const list = $('payeeList');
  list.innerHTML = '';
  if (state.payees.length === 0) {
    list.innerHTML = '<li class="empty">No invoices yet, so no payees to show.</li>';
  }
  for (const payee of state.payees) {
    const li = document.createElement('li');
    const dot = document.createElement('span');
    dot.textContent = payee.allowed ? '✓' : '✕';
    dot.style.color = payee.allowed ? 'var(--accent)' : 'var(--danger)';
    const addr = document.createElement('span');
    addr.textContent = short(payee.address);
    const status = document.createElement('span');
    status.className = `status ${payee.allowed ? 'yes' : 'no'}`;
    status.textContent = payee.allowed ? 'allowed' : 'not allowed';
    li.append(dot, addr, status);
    list.append(li);
  }
}

function renderInvoices() {
  const list = $('invoiceList');
  list.innerHTML = '';
  $('invoiceCount').textContent = `${state.invoices.length} on this merchant`;

  if (state.invoices.length === 0) {
    list.innerHTML = '<li class="empty">No invoices yet.</li>';
    return;
  }

  for (const invoice of state.invoices) {
    const li = document.createElement('li');
    li.tabIndex = 0;
    li.setAttribute('role', 'button');
    if (selectedInvoice === invoice.id) li.setAttribute('aria-current', 'true');

    const amount = document.createElement('span');
    amount.className = 'amount';
    amount.textContent = units(invoice.amount, state.token.decimals);

    const who = document.createElement('span');
    who.className = 'who';
    who.textContent = short(invoice.payee);

    const spacer = document.createElement('span');
    spacer.className = 'spacer';

    const tag = document.createElement('span');
    tag.className = `status-tag status-${invoice.status}`;
    tag.textContent = invoice.status;

    li.append(amount, who, spacer, tag);

    const select = () => selectInvoice(invoice.id);
    li.addEventListener('click', select);
    li.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select(); }
    });

    list.append(li);
  }
}

function renderDecision(decision, invoice) {
  $('decisionEmpty').hidden = true;
  $('decisionBody').hidden = false;
  $('decisionHint').textContent = invoice ? short(invoice.payee) : '';

  const verdict = $('verdict');
  verdict.classList.toggle('allowed', decision.allowed);
  verdict.classList.toggle('refused', !decision.allowed);
  $('verdictLabel').textContent = decision.allowed ? 'Allowed' : 'Refused';
  $('verdictReason').textContent = decision.explanation ?? decision.reason;

  $('dInvoiceId').textContent = invoice ? `${invoice.id.slice(0, 10)}…${invoice.id.slice(-6)}` : '-';
  $('dPayee').textContent = invoice ? short(invoice.payee) : '-';
  $('dAmount').textContent = invoice ? units(invoice.amount, state.token.decimals) : '-';

  const allowed = state.payees.find((p) => invoice && p.address === invoice.payee);
  $('dAllowed').textContent = allowed ? (allowed.allowed ? 'yes' : 'no') : '-';

  $('payButton').disabled = busy || invoice.status !== 'created';
  $('askButton').disabled = busy;
}

function renderTrail(events) {
  const list = $('eventList');
  list.innerHTML = '';
  if (!events || events.length === 0) {
    list.innerHTML = '<li class="empty">Nothing yet. Pay an invoice and it will show up here.</li>';
    return;
  }
  for (const event of events) {
    const li = document.createElement('li');
    if (event.kind === 'refused') li.className = 'refused';
    if (event.kind === 'allowed') li.className = 'allowed';

    const when = document.createElement('span');
    when.className = 'when';
    when.textContent = ago(event.timestamp);

    const what = document.createElement('span');
    what.className = 'what';
    what.textContent = event.what;

    li.append(when, what);

    if (event.why) {
      const why = document.createElement('span');
      why.className = 'why';
      why.textContent = `“${event.why}”`;
      li.append(why);
    }

    if (event.txHash) {
      const link = document.createElement('a');
      link.className = 'hash';
      link.href = `https://explorer-test.qday.info/tx/${event.txHash}`;
      link.target = '_blank';
      link.rel = 'noopener';
      link.textContent = 'tx';
      li.append(link);
    }

    list.append(li);
  }
}

/* ── Actions ─────────────────────────────────────────────────── */

async function selectInvoice(invoiceId) {
  selectedInvoice = invoiceId;
  const invoice = state.invoices.find((i) => i.id === invoiceId);
  renderInvoices();

  const result = $('actionResult');
  result.textContent = 'Asking the policy…';
  result.className = 'result';

  try {
    const response = await fetch('/api/decide', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ invoiceId }),
    });
    const decision = await response.json();
    renderDecision(decision, invoice);
    result.textContent = '';
  } catch (err) {
    result.textContent = `Could not reach the chain: ${err.message}`;
    result.className = 'result no';
  }
}

async function askTheAgent() {
  if (!selectedInvoice || busy) return;
  busy = true;
  renderDecision({ allowed: false, explanation: 'Asking…' }, state.invoices.find((i) => i.id === selectedInvoice));

  try {
    const response = await fetch('/api/pay', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ invoiceId: selectedInvoice }),
    });
    const result = await response.json();

    if (result.error) {
      $('actionResult').textContent = result.error;
      $('actionResult').className = 'result no';
    } else if (result.paid) {
      $('actionResult').textContent = `Paid. ${result.txHash?.slice(0, 14)}…`;
      $('actionResult').className = 'result ok';
    } else {
      $('actionResult').textContent = `Refused, ${result.reason}`;
      $('actionResult').className = 'result no';
    }
    await refresh();
  } catch (err) {
    $('actionResult').textContent = err.message;
    $('actionResult').className = 'result no';
  } finally {
    busy = false;
  }
}

async function togglePause() {
  if (busy) return;
  const next = !state.policy.paused;
  busy = true;
  try {
    await fetch('/api/pause', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ paused: next }),
    });
    await refresh();
  } finally {
    busy = false;
  }
}

/* ── Polling ─────────────────────────────────────────────────── */

async function refresh() {
  try {
    const response = await fetch('/api/state');
    const next = await response.json();
    if (next.error) {
      $('chainName').textContent = next.error;
      return;
    }
    state = next;
    renderPolicy();
    renderInvoices();
    renderTrail(state.events);

    if (selectedInvoice) {
      const invoice = state.invoices.find((i) => i.id === selectedInvoice);
      if (invoice) {
        const decision = await fetch('/api/decide', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ invoiceId: selectedInvoice }),
        }).then((r) => r.json());
        renderDecision(decision, invoice);
      }
    }
  } catch (err) {
    $('chainName').textContent = 'chain unreachable';
  }
}

$('askButton').addEventListener('click', () => {
  if (selectedInvoice) selectInvoice(selectedInvoice);
});
$('payButton').addEventListener('click', askTheAgent);
$('pauseButton').addEventListener('click', togglePause);

refresh();
setInterval(refresh, 5000);
