#!/bin/bash

# Mainnet-only EVM ownership acceptance flow.
# Assumptions:
# - transferOwnership(real COA) was already initiated by the current EVM owner.
# - The Cadence deployer account already has its COA created on mainnet.

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
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"

flow_cmd() {
    flow -f "$FLOW_CONFIG_PATH" "$@"
}

normalize_address() {
    local value="$1"
    value="${value#0x}"
    value="${value#0X}"
    echo "0x$(echo "$value" | tr '[:upper:]' '[:lower:]')"
}

echo "=========================================="
echo "🚀 Mainnet EVM Ownership Acceptance"
echo "=========================================="
echo "Network: mainnet"
echo "Signer:   $FLOW_SIGNER ($FLOW_ACCOUNT_ADDRESS_HEX)"
echo "EVM App:  $MAINNET_EVM_CONTRACT_ADDRESS"
echo ""

echo "🔍 Step 1: Confirming real COA and pending owner..."

COA_ADDRESS=$(flow_cmd scripts execute "$PROJECT_ROOT/cadence/scripts/get_coa_address.cdc" "$FLOW_ACCOUNT_ADDRESS" \
    --network "$FLOW_NETWORK" \
    --output json | jq -r '.value')

if [ -z "$COA_ADDRESS" ] || [ "$COA_ADDRESS" = "null" ]; then
    echo "❌ Error: Could not get COA address from Cadence account."
    exit 1
fi

echo "$COA_ADDRESS" > "$PROJECT_ROOT/local/.mainnet_coa_address"

NORMALIZED_COA_ADDRESS="$(normalize_address "$COA_ADDRESS")"
CURRENT_OWNER="$(normalize_address "$(cast call --rpc-url "$EVM_RPC_URL" "$MAINNET_EVM_CONTRACT_ADDRESS" "owner()(address)")")"
PENDING_OWNER="$(normalize_address "$(cast call --rpc-url "$EVM_RPC_URL" "$MAINNET_EVM_CONTRACT_ADDRESS" "pendingOwner()(address)")")"

echo "   COA:           $NORMALIZED_COA_ADDRESS"
echo "   owner():       $CURRENT_OWNER"
echo "   pendingOwner(): $PENDING_OWNER"

if [ "$PENDING_OWNER" = "$ZERO_ADDRESS" ]; then
    echo ""
    echo "❌ Error: No pending owner is set on the EVM contract."
    echo "   The current owner must call transferOwnership($NORMALIZED_COA_ADDRESS) first."
    exit 1
fi

if [ "$PENDING_OWNER" != "$NORMALIZED_COA_ADDRESS" ]; then
    echo ""
    echo "❌ Error: pendingOwner() does not match the real COA."
    echo "   Real COA:       $NORMALIZED_COA_ADDRESS"
    echo "   pendingOwner(): $PENDING_OWNER"
    exit 1
fi

echo ""
echo "✅ pendingOwner matches the real COA"
echo ""

echo "🔐 Step 2: Accepting ownership from the COA..."

flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/admin/accept_ownership.cdc" \
    "$MAINNET_EVM_CONTRACT_ADDRESS" \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999

echo ""
echo "🔍 Step 3: Verifying final EVM ownership state..."

FINAL_OWNER="$(normalize_address "$(cast call --rpc-url "$EVM_RPC_URL" "$MAINNET_EVM_CONTRACT_ADDRESS" "owner()(address)")")"
FINAL_PENDING_OWNER="$(normalize_address "$(cast call --rpc-url "$EVM_RPC_URL" "$MAINNET_EVM_CONTRACT_ADDRESS" "pendingOwner()(address)")")"

echo "   owner():        $FINAL_OWNER"
echo "   pendingOwner(): $FINAL_PENDING_OWNER"

if [ "$FINAL_OWNER" != "$NORMALIZED_COA_ADDRESS" ]; then
    echo ""
    echo "❌ Error: owner() is not the COA after acceptance."
    exit 1
fi

if [ "$FINAL_PENDING_OWNER" != "$ZERO_ADDRESS" ]; then
    echo ""
    echo "❌ Error: pendingOwner() was not cleared after acceptance."
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ EVM Ownership Accepted"
echo "=========================================="
echo ""
echo "Final owner: $FINAL_OWNER"
echo "pendingOwner: $FINAL_PENDING_OWNER"
echo ""
