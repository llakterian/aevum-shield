#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Brings up a complete local Aevum Shield: a chain, the contracts, and the
# demo app pointed at them.
#
#   ./script/local-up.sh
#
# It is the rehearsal path. Everything it does is also possible on the real
# Aevum Testnet, but the testnet needs a funded wallet and this does not.
#
# The demo app ends up on http://localhost:8080 with three invoices ready:
# one that pays, one refused for being over the cap, one refused because
# the payee is not on the allowlist.
#
# Addresses and invoice ids are read back from the chain, not from the
# deploy script's output. `forge script` simulates and then broadcasts,
# and the two can disagree about `block.chainid` — which is one of the
# terms in the invoice id hash. Trusting the printed ids once produced a
# set of ids that did not exist. The chain is the only authority here.

set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

RPC_PORT="${RPC_PORT:-8545}"
APP_PORT="${PORT:-8080}"
# Anvil's first three default keys. They are public test keys with no
# value — anvil prints them on every startup, they are published in
# Foundry's own documentation, and they exist only on a chain that this
# script started. They are used for three different roles so that the
# agent harness has something real to be refused by:
#
#   0  the payer   — owns the policy and sets the rules
#   1  the merchant — owns the escrow and writes the invoices
#   2  the agent   — an operator, allowed to ask the policy to pay
#
# Never use these keys on any chain that matters.
ANVIL_PAYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ANVIL_MERCHANT_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
ANVIL_AGENT_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
ENV_FILE="${ENV_FILE:-/tmp/opencode/app-env.sh}"
BROADCAST="broadcast/Local.s.sol/31337/run-latest.json"

echo "==> building"
# Forced. A failed compile leaves a stub artifact behind and Foundry's
# cache can then decide the script is up to date, which produces the
# unhelpful "No contract bytecode" at the deploy step instead of the
# compile error that actually caused it.
FOUNDRY_PROFILE=local forge build --force >/dev/null

echo "==> starting anvil on :${RPC_PORT}"
if ! curl -s --max-time 2 -X POST "http://127.0.0.1:${RPC_PORT}" \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null 2>&1; then
  nohup anvil --port "${RPC_PORT}" --silent >/tmp/opencode/anvil.log 2>&1 &
  disown || true
  for _ in $(seq 1 20); do
    sleep 0.5
    curl -s --max-time 2 -X POST "http://127.0.0.1:${RPC_PORT}" \
      -H 'content-type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null 2>&1 && break
  done
fi
echo "    chain id $(cast chain-id --rpc-url "http://127.0.0.1:${RPC_PORT}")"

echo "==> deploying"
DEPLOYER_PRIVATE_KEY="${ANVIL_PAYER_KEY}" \
MERCHANT_PRIVATE_KEY="${ANVIL_MERCHANT_KEY}" \
AGENT_PRIVATE_KEY="${ANVIL_AGENT_KEY}" \
  FOUNDRY_PROFILE=local \
  forge script script/Local.s.sol:Local --broadcast \
  --rpc-url "http://127.0.0.1:${RPC_PORT}" >/tmp/opencode/local-deploy.txt 2>&1 || {
    echo "    the deployment failed:" >&2
    tail -30 /tmp/opencode/local-deploy.txt >&2
    exit 1
  }

if [ ! -f "${BROADCAST}" ]; then
  echo "    no broadcast file at ${BROADCAST}" >&2
  tail -30 /tmp/opencode/local-deploy.txt >&2
  exit 1
fi

echo "==> reading the deployment back from the chain"
python3 - "$ENV_FILE" "$BROADCAST" <<'PY'
import json
import subprocess
import sys

env_path, broadcast_path = sys.argv[1], sys.argv[2]
rpc = 'http://127.0.0.1:8545'

broadcast = json.load(open(broadcast_path))

# The contract addresses come from the broadcast record, which records the
# transactions that were actually sent.
names = {}
for tx in broadcast.get('transactions', []):
    name = tx.get('contractName')
    address = tx.get('contractAddress')
    if name and address and name not in names:
        names[name] = address

wanted = {'MockToken': 'TUSD8', 'InvoiceEscrow': 'ESCROW', 'PayPolicy': 'POLICY', 'PaymentAgent': 'AGENT'}
missing = [k for k in wanted if k not in names]
if missing:
    print(f'  missing contracts in the broadcast: {missing}', file=sys.stderr)
    raise SystemExit(1)

escrow = names['InvoiceEscrow']


def call(to, data):
    """One eth_call, straight to the node."""
    payload = json.dumps({
        'jsonrpc': '2.0', 'id': 1, 'method': 'eth_call',
        'params': [{'to': to, 'data': data}, 'latest'],
    })
    out = subprocess.run(
        ['curl', '-s', '--max-time', '15', '-X', 'POST', rpc,
         '-H', 'content-type: application/json', '--data', payload],
        capture_output=True, text=True, check=True,
    ).stdout
    reply = json.loads(out)
    if 'result' not in reply:
        raise SystemExit(f'  eth_call failed: {reply.get("error")}')
    return reply['result']


def selector(signature):
    out = subprocess.run(
        ['cast', 'sig', signature], capture_output=True, text=True, check=True,
    ).stdout.strip()
    return out[2:] if out.startswith('0x') else out


def invoice_ids(count):
    sel = selector('invoiceIdAt(uint256)')
    ids = []
    for i in range(count):
        data = '0x' + sel + format(i, '064x')
        raw = call(escrow, data)[2:]
        ids.append('0x' + raw)
    return ids


# How many invoices did the deploy create? Read the counter, then the ids.
count_raw = call(escrow, '0x' + selector('invoiceCount()'))
count = int(count_raw, 16)
if count < 3:
    print(f'  expected at least 3 invoices, found {count}', file=sys.stderr)
    raise SystemExit(1)

ids = invoice_ids(count)

# The order is fixed by the deploy script: payable, over cap, unknown payee.
if count > 3:
    ids = ids[:3]

env = f"""# Written by script/local-up.sh
export AEVUM_RPC_URL={rpc}
export AEVUM_CHAIN_ID=31337
export TUSD8={names['MockToken']}
export ESCROW={escrow}
export POLICY={names['PayPolicy']}
export AGENT={names['PaymentAgent']}
export PAYEE=0x5Ec280C6196cc3669e88FED0c1185920302bD0ED
export MERCHANT=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export MERCHANT_PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
export AGENT_PRIVATE_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
export PORT=8080
export INV_PAYABLE={ids[0]}
export INV_OVERCAP={ids[1]}
export INV_UNKNOWN={ids[2]}
"""
open(env_path, 'w').write(env)

print('    token  ', names['MockToken'])
print('    escrow ', escrow)
print('    policy ', names['PayPolicy'])
print('    agent  ', names['PaymentAgent'])
print('    payable     ', ids[0])
print('    over cap    ', ids[1])
print('    unknown payee', ids[2])
PY

echo "==> restarting the demo app on :${APP_PORT}"
# A pid file, not `pkill`. The pattern for pkill matches the command line
# of the shell that is running this script, which kills the script itself.
PID_FILE=/tmp/opencode/aevum-shield-app.pid
if [ -f "${PID_FILE}" ]; then
  kill "$(cat "${PID_FILE}")" >/dev/null 2>&1 || true
  rm -f "${PID_FILE}"
fi
sleep 1
cd app
# shellcheck disable=SC1090
source "${ENV_FILE}"
nohup node server.mjs >/tmp/opencode/app.log 2>&1 &
echo $! >"${PID_FILE}"
disown || true

for _ in $(seq 1 30); do
  sleep 0.5
  curl -s --max-time 2 "http://localhost:${APP_PORT}/api/state" >/dev/null 2>&1 && break
done

if curl -s --max-time 10 "http://localhost:${APP_PORT}/api/state" | grep -q '"error"'; then
  echo "    the app came up but could not read the chain:" >&2
  curl -s --max-time 10 "http://localhost:${APP_PORT}/api/state" >&2
  exit 1
fi

echo
echo "    demo:  http://localhost:${APP_PORT}"
echo "    env:   ${ENV_FILE}"
