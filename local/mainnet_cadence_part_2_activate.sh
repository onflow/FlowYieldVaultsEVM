#!/bin/bash

# Mainnet-only Cadence activation flow.
# Assumptions:
# - The Cadence prep script already ran and created the real COA.
# - The EVM owner already updated authorizedCOA on the Solidity contract.
# - Beta cap is already issued to the worker account.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

FLOW_CONFIG_PATH="$PROJECT_ROOT/flow.json"
FLOW_NETWORK="mainnet"
FLOW_SIGNER="${FLOW_SIGNER:-mainnet-account}"
FLOW_ACCOUNT_ADDRESS="${FLOW_ACCOUNT_ADDRESS:-a7d9a1bece1378a3}"
FLOW_ACCOUNT_ADDRESS="${FLOW_ACCOUNT_ADDRESS#0x}"
FLOW_ACCOUNT_ADDRESS="${FLOW_ACCOUNT_ADDRESS#0X}"
FLOW_ACCOUNT_ADDRESS_HEX="0x${FLOW_ACCOUNT_ADDRESS}"

MAINNET_EVM_CONTRACT_ADDRESS="${MAINNET_EVM_CONTRACT_ADDRESS:-0x6e8563dc44757c71a28f253cdf54410bf1ec9bd8}"
if [[ "$MAINNET_EVM_CONTRACT_ADDRESS" != 0x* && "$MAINNET_EVM_CONTRACT_ADDRESS" != 0X* ]]; then
    MAINNET_EVM_CONTRACT_ADDRESS="0x${MAINNET_EVM_CONTRACT_ADDRESS}"
fi

EVM_RPC_URL="${MAINNET_RPC_URL:-https://mainnet.evm.nodes.onflow.org}"
WFLOW_ADDRESS="${WFLOW_ADDRESS:-0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e}"
WETH_ADDRESS="${WETH_ADDRESS:-0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590}"
WBTC_ADDRESS="${WBTC_ADDRESS:-0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579}"
PYUSD0_ADDRESS="${PYUSD0_ADDRESS:-0x99aF3EeA856556646C98c8B9b2548Fe815240750}"
EVM_EXPLORER_BASE_URL="${EVM_EXPLORER_BASE_URL:-https://evm.flowscan.io}"
COA_TARGET_BALANCE="${COA_TARGET_BALANCE:-${COA_FUNDING_AMOUNT:-400.0}}"
SCHEDULER_BASE_EFFORT="${SCHEDULER_BASE_EFFORT:-950}"
SCHEDULER_PER_REQUEST_EFFORT="${SCHEDULER_PER_REQUEST_EFFORT:-250}"
SCHEDULER_WAKEUP_INTERVAL="${SCHEDULER_WAKEUP_INTERVAL:-10.0}"
MAX_PROCESSING_REQUESTS="${MAX_PROCESSING_REQUESTS:-5}"
MAX_UINT256="115792089237316195423570985008687907853269984665640564039457584007913129639935"

flow_cmd() {
    flow -f "$FLOW_CONFIG_PATH" "$@"
}

normalize_address() {
    local value="$1"
    value="${value#0x}"
    value="${value#0X}"
    echo "0x$(echo "$value" | tr '[:upper:]' '[:lower:]')"
}

calculate_top_up() {
    local target_balance="$1"
    local current_balance_wei="$2"

    python3 - "$target_balance" "$current_balance_wei" <<'PY'
from decimal import Decimal, ROUND_DOWN, ROUND_UP
import sys

target = Decimal(sys.argv[1])
current_wei = Decimal(sys.argv[2])
quantum = Decimal("0.00000001")
current_flow = (current_wei / Decimal(10**18)).quantize(quantum, rounding=ROUND_DOWN)

if target <= 0:
    print(current_flow)
    print(Decimal("0").quantize(quantum))
    print("0")
    raise SystemExit

if current_flow >= target:
    print(current_flow)
    print(Decimal("0").quantize(quantum))
    print("0")
else:
    top_up = (target - current_flow).quantize(quantum, rounding=ROUND_UP)
    print(current_flow)
    print(top_up)
    print("1")
PY
}

echo "=========================================="
echo "🚀 Mainnet Cadence Activation"
echo "=========================================="
echo "Network: mainnet"
echo "Signer:   $FLOW_SIGNER ($FLOW_ACCOUNT_ADDRESS_HEX)"
echo "EVM App:  $MAINNET_EVM_CONTRACT_ADDRESS"
echo "Mode:     Worker + scheduler activation"
echo ""

# ==========================================
# Step 1: Confirm the real COA and EVM authorizedCOA match
# ==========================================
echo "🔍 Step 1: Confirming the real COA matches authorizedCOA on EVM..."

COA_ADDRESS=$(flow_cmd scripts execute "$PROJECT_ROOT/cadence/scripts/get_coa_address.cdc" "$FLOW_ACCOUNT_ADDRESS" \
    --network "$FLOW_NETWORK" \
    --output json | jq -r '.value')

if [ -z "$COA_ADDRESS" ] || [ "$COA_ADDRESS" == "null" ]; then
    echo "❌ Error: Could not get COA address. Run the prep script first."
    exit 1
fi

echo "$COA_ADDRESS" > "$PROJECT_ROOT/local/.mainnet_coa_address"

AUTHORIZED_COA=$(cast call \
    --rpc-url "$EVM_RPC_URL" \
    "$MAINNET_EVM_CONTRACT_ADDRESS" \
    "authorizedCOA()(address)")

NORMALIZED_COA_ADDRESS="$(normalize_address "$COA_ADDRESS")"
NORMALIZED_AUTHORIZED_COA="$(normalize_address "$AUTHORIZED_COA")"

if [ "$NORMALIZED_COA_ADDRESS" != "$NORMALIZED_AUTHORIZED_COA" ]; then
    echo "❌ Error: authorizedCOA on EVM does not match the real Cadence COA"
    echo "   Cadence COA:     $NORMALIZED_COA_ADDRESS"
    echo "   EVM authorized:  $NORMALIZED_AUTHORIZED_COA"
    echo "   Update authorizedCOA on the EVM contract first."
    exit 1
fi

echo ""
echo "✅ authorizedCOA matches the real Cadence COA: $NORMALIZED_COA_ADDRESS"
echo ""

# ==========================================
# Step 2: Ensure the COA has enough EVM balance
# ==========================================
echo "💰 Step 2: Ensuring COA balance is at least $COA_TARGET_BALANCE FLOW..."

CURRENT_COA_BALANCE_WEI=$(cast balance \
    --rpc-url "$EVM_RPC_URL" \
    "$NORMALIZED_COA_ADDRESS")

mapfile -t TOP_UP_INFO < <(calculate_top_up "$COA_TARGET_BALANCE" "$CURRENT_COA_BALANCE_WEI")
CURRENT_COA_BALANCE_FLOW="${TOP_UP_INFO[0]}"
COA_TOP_UP_AMOUNT="${TOP_UP_INFO[1]}"
COA_NEEDS_TOP_UP="${TOP_UP_INFO[2]}"

echo "   Current COA balance: $CURRENT_COA_BALANCE_FLOW FLOW"

if [ "$COA_NEEDS_TOP_UP" = "1" ]; then
    echo "   Topping up: $COA_TOP_UP_AMOUNT FLOW"
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/deposit_flow_to_coa.cdc" \
        "$COA_TOP_UP_AMOUNT" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999
    echo ""
    echo "✅ COA topped up by $COA_TOP_UP_AMOUNT FLOW"
else
    echo "✅ COA already meets the target balance"
fi
echo ""

# ==========================================
# Step 3: Approve refund tokens from the real COA
# ==========================================
echo "🔐 Step 3: Approving refund tokens from COA..."

approve_refund_token() {
    local symbol="$1"
    local token_address="$2"

    echo "   - Approving $symbol ($token_address)"
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/approve_erc20_from_coa.cdc" \
        "$token_address" \
        "$MAINNET_EVM_CONTRACT_ADDRESS" \
        "$MAX_UINT256" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999
}

approve_refund_token "WFLOW" "$WFLOW_ADDRESS"
approve_refund_token "WETH" "$WETH_ADDRESS"
approve_refund_token "WBTC" "$WBTC_ADDRESS"
approve_refund_token "PYUSD0" "$PYUSD0_ADDRESS"

echo ""
echo "✅ Refund tokens approved for contract refunds"
echo ""

set_execution_effort_constant() {
    local key="$1"
    local value="$2"

    echo "   - Setting $key = $value"
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/set_execution_effort_constant.cdc" \
        "$key" \
        "$value" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999
}

set_scheduler_wakeup_interval() {
    local value="$1"

    echo "   - Setting schedulerWakeupInterval = $value"
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/set_scheduler_wakeup_interval.cdc" \
        "$value" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999
}

set_max_processing_requests() {
    local value="$1"

    echo "   - Setting maxProcessingRequests = $value"
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/set_max_processing_requests.cdc" \
        "$value" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999
}

# ==========================================
# Step 4: Setup worker or update the address if it already exists
# ==========================================
echo "🔧 Step 4: Setting up FlowYieldVaultsEVM Worker..."
echo "   FlowYieldVaultsRequests address: $MAINNET_EVM_CONTRACT_ADDRESS"

if flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/setup_worker_with_badge.cdc" \
    "$MAINNET_EVM_CONTRACT_ADDRESS" \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999; then
    echo ""
    echo "✅ Worker initialized and FlowYieldVaultsRequests address set"
else
    echo ""
    echo "⚠️  setup_worker_with_badge failed; attempting rerun-safe address update path..."
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/update_flow_vaults_requests_address.cdc" \
        "$MAINNET_EVM_CONTRACT_ADDRESS" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999

    echo ""
    echo "✅ Existing worker kept; FlowYieldVaultsRequests address updated"
fi

echo ""

# ==========================================
# Step 5: Apply tuned scheduler configuration
# ==========================================
echo "⚙️  Step 5: Applying scheduler configuration..."

set_execution_effort_constant "schedulerBaseEffort" "$SCHEDULER_BASE_EFFORT"
set_execution_effort_constant "schedulerPerRequestEffort" "$SCHEDULER_PER_REQUEST_EFFORT"
set_scheduler_wakeup_interval "$SCHEDULER_WAKEUP_INTERVAL"
set_max_processing_requests "$MAX_PROCESSING_REQUESTS"

echo ""
echo "✅ Scheduler configuration applied"
echo ""

# ==========================================
# Step 6: Initialize scheduler handlers and schedule the first execution
# ==========================================
echo "🔧 Step 6: Initializing FlowYieldVaultsEVMWorkerOps handlers and scheduler..."

flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/scheduler/init_and_schedule.cdc" \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999

echo ""
echo "✅ Transaction handler initialized and initial execution scheduled"
echo ""

# ==========================================
# Step 7: Refresh exported addresses
# ==========================================
echo "📦 Step 7: Exporting artifacts and refreshing contract addresses..."

"$PROJECT_ROOT/scripts/export-artifacts.sh" \
    --network "$FLOW_NETWORK" \
    --evm-address "$MAINNET_EVM_CONTRACT_ADDRESS" \
    --cadence-address "$FLOW_ACCOUNT_ADDRESS_HEX"

echo ""
echo "✅ Artifacts exported and addresses refreshed"
echo ""

echo "=========================================="
echo "✅ Mainnet Cadence Activation Complete"
echo "=========================================="
echo ""
echo "📋 Summary:"
echo "   COA:              $NORMALIZED_COA_ADDRESS"
echo "   EVM Contract:     $MAINNET_EVM_CONTRACT_ADDRESS"
echo "   Cadence Deployer: $FLOW_ACCOUNT_ADDRESS_HEX"
echo "   authorizedCOA:    Verified"
echo "   COA Balance:      $CURRENT_COA_BALANCE_FLOW FLOW before top-up"
echo "   COA Target:       $COA_TARGET_BALANCE FLOW"
echo "   Token Approvals:  WFLOW, WETH, WBTC, PYUSD0"
echo "   Scheduler Effort: base=$SCHEDULER_BASE_EFFORT perRequest=$SCHEDULER_PER_REQUEST_EFFORT"
echo "   Scheduler Wakeup: $SCHEDULER_WAKEUP_INTERVAL seconds"
echo "   Max Processing:   $MAX_PROCESSING_REQUESTS"
echo "   Worker Setup:     Completed"
echo "   Scheduler Init:   Completed"
echo ""
echo "🔗 EVM Contract:"
echo "   $EVM_EXPLORER_BASE_URL/address/$MAINNET_EVM_CONTRACT_ADDRESS"
echo ""
