#!/bin/bash

# Deploy and verify FlowYieldVaultsRequests (Solidity) and Cadence contracts
# Run this script from the project root directory
# Uses COA (Cadence Owned Account) for EVM deployment - signed via Google KMS

set -e  # Exit on any error
set -o pipefail

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load environment variables from .env file in project root
set -a
source "$PROJECT_ROOT/.env"
set +a

# Resolve testnet account address used by Cadence scripts.
# Prefer .env override, then fallback to flow.json account config.
TESTNET_ACCOUNT_ADDRESS="${TESTNET_ACCOUNT_ADDRESS:-}"
if [ -z "$TESTNET_ACCOUNT_ADDRESS" ]; then
    TESTNET_ACCOUNT_ADDRESS=$(jq -r '.accounts["testnet-account"].address // empty' "$PROJECT_ROOT/flow.json" 2>/dev/null || true)
fi

# Cadence Address arguments should be sent without 0x prefix.
TESTNET_ACCOUNT_ADDRESS="${TESTNET_ACCOUNT_ADDRESS#0x}"
TESTNET_ACCOUNT_ADDRESS="${TESTNET_ACCOUNT_ADDRESS#0X}"

if [ -z "$TESTNET_ACCOUNT_ADDRESS" ]; then
    echo "❌ Error: Missing testnet account address. Set TESTNET_ACCOUNT_ADDRESS in .env or configure accounts.testnet-account.address in flow.json."
    exit 1
fi

FLOW_CONFIG_PATH="$PROJECT_ROOT/flow.json"
FLOW_NETWORK="testnet"
FLOW_SIGNER="testnet-account"
FLOW_ADMIN_SIGNER="${FLOW_ADMIN_SIGNER:-testnet-admin}"
# Beta grant tx role defaults:
# - proposer: worker signer account (avoids admin multisig proposer issues)
# - payer: admin signer account
# - authorizers: admin first (prepare(admin, user)), then worker signer
FLOW_BETA_GRANT_PROPOSER="${FLOW_BETA_GRANT_PROPOSER:-$FLOW_SIGNER}"
FLOW_BETA_GRANT_PAYER="${FLOW_BETA_GRANT_PAYER:-$FLOW_ADMIN_SIGNER}"
FLOW_BETA_GRANT_AUTHORIZERS="${FLOW_BETA_GRANT_AUTHORIZERS:-$FLOW_ADMIN_SIGNER,$FLOW_SIGNER}"
BETA_CHECK_SCRIPT="$PROJECT_ROOT/lib/FlowYieldVaults/cadence/scripts/flow-yield-vaults/get_beta_cap.cdc"
BETA_GRANT_TX="$PROJECT_ROOT/lib/FlowYieldVaults/cadence/transactions/flow-yield-vaults/admin/grant_beta.cdc"

flow_cmd() {
    flow -f "$FLOW_CONFIG_PATH" "$@"
}

contract_exists_on_account() {
    local account_json="$1"
    local contract_name="$2"

    jq -e --arg contract_name "$contract_name" '
        if (.contracts | type) == "array" then
            any(.contracts[]?;
                if (type) == "object" then
                    (.name // empty) == $contract_name
                elif (type) == "string" then
                    . == $contract_name
                else
                    false
                end
            )
        elif (.contracts | type) == "object" then
            .contracts[$contract_name] != null
        else
            false
        end
    ' >/dev/null <<<"$account_json"
}

is_incompatible_update_error() {
    local output="$1"
    [[ "$output" == *"cannot deploy invalid contract"* || "$output" == *"mismatching field"* || "$output" == *"found new field"* || "$output" == *"missing event declaration"* ]]
}

deploy_or_update_cadence_contract() {
    local contract_name="$1"
    local contract_path="$2"
    local account_json=""
    local action=""
    local verb=""
    local output=""

    account_json=$(flow_cmd accounts get "$TESTNET_ACCOUNT_ADDRESS" \
        --network "$FLOW_NETWORK" \
        --include contracts \
        --output json)

    if contract_exists_on_account "$account_json" "$contract_name"; then
        action="update-contract"
        verb="update"
    else
        action="add-contract"
        verb="deploy"
    fi

    echo "   - Attempting to ${verb} ${contract_name}..."
    if output=$(flow_cmd accounts "$action" "$contract_path" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" 2>&1); then
        echo "$output"
        return 0
    fi

    echo "$output"

    if [[ "$output" == *"contract already exists and is the same as the contract provided for update"* ]]; then
        echo "✅ ${contract_name} already up to date on-chain"
        return 0
    fi

    if is_incompatible_update_error "$output"; then
        echo "❌ On-chain compatibility blocked ${contract_name} ${verb}. Stopping deploy."
        return 1
    fi

    echo "❌ Failed to ${verb} ${contract_name}."
    return 1
}

ensure_beta_badge_for_worker() {
    local beta_status_output=""
    local has_beta=""

    echo "🪪 Checking FlowYieldVaults beta badge for $FLOW_SIGNER ($TESTNET_ACCOUNT_ADDRESS)..."
    beta_status_output=$(flow_cmd scripts execute "$BETA_CHECK_SCRIPT" "$TESTNET_ACCOUNT_ADDRESS" \
        --network "$FLOW_NETWORK" \
        --output json 2>/dev/null || true)
    has_beta=$(echo "$beta_status_output" | jq -r '
        if has("value") and (.value | type) == "boolean" then
            (.value | tostring)
        else
            empty
        end
    ' 2>/dev/null || true)

    if [ "$has_beta" = "true" ]; then
        echo "✅ Beta badge already configured"
        return 0
    fi

    if [ "$has_beta" != "false" ]; then
        echo "❌ Unable to determine beta badge state for $TESTNET_ACCOUNT_ADDRESS"
        if [ -n "$beta_status_output" ]; then
            echo "$beta_status_output"
        fi
        return 1
    fi

    echo "⚠️  Beta badge missing. Granting beta from $FLOW_ADMIN_SIGNER to $FLOW_SIGNER..."
    echo "   - proposer: $FLOW_BETA_GRANT_PROPOSER"
    echo "   - payer: $FLOW_BETA_GRANT_PAYER"
    echo "   - authorizers: $FLOW_BETA_GRANT_AUTHORIZERS"
    flow_cmd transactions send "$BETA_GRANT_TX" \
        --network "$FLOW_NETWORK" \
        --proposer "$FLOW_BETA_GRANT_PROPOSER" \
        --payer "$FLOW_BETA_GRANT_PAYER" \
        --authorizer "$FLOW_BETA_GRANT_AUTHORIZERS" \
        --compute-limit 9999

    beta_status_output=$(flow_cmd scripts execute "$BETA_CHECK_SCRIPT" "$TESTNET_ACCOUNT_ADDRESS" \
        --network "$FLOW_NETWORK" \
        --output json)
    has_beta=$(echo "$beta_status_output" | jq -r '
        if has("value") and (.value | type) == "boolean" then
            (.value | tostring)
        else
            empty
        end
    ')
    if [ "$has_beta" != "true" ]; then
        echo "❌ Beta badge grant did not verify successfully"
        return 1
    fi

    echo "✅ Beta badge granted"
}

echo "=========================================="
echo "🚀 Deploying Flow YieldVaults Contracts"
echo "=========================================="
echo ""

# ==========================================
# Step 1: Setup COA (Cadence Owned Account)
# ==========================================
echo "🔑 Step 1: Setting up COA (Cadence Owned Account)..."

flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/setup_coa.cdc" \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999

# Get the COA address
COA_ADDRESS=$(flow_cmd scripts execute "$PROJECT_ROOT/cadence/scripts/get_coa_address.cdc" "$TESTNET_ACCOUNT_ADDRESS" --network "$FLOW_NETWORK" --output json | jq -r '.value')

if [ -z "$COA_ADDRESS" ] || [ "$COA_ADDRESS" == "null" ]; then
    echo "❌ Error: Could not get COA address"
    exit 1
fi

echo ""
echo "✅ COA ready at EVM address: $COA_ADDRESS"
echo ""

# ==========================================
# Step 2: Fund COA with FLOW
# ==========================================
echo "💰 Step 2: Funding COA with 10,000 FLOW..."

flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/deposit_flow_to_coa.cdc" \
    10000.0 \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999

echo ""
echo "✅ COA funded with 10,000 FLOW"
echo ""

# ==========================================
# Step 3: Build and Deploy EVM Contract via COA
# ==========================================
echo "📦 Step 3: Building and deploying Solidity contract via COA..."

# Build the contract
cd "$PROJECT_ROOT/solidity"
forge build
cd "$PROJECT_ROOT"

# Get the bytecode from the compiled contract
BYTECODE=$(jq -r '.bytecode.object' "$PROJECT_ROOT/solidity/out/FlowYieldVaultsRequests.sol/FlowYieldVaultsRequests.json")

# Remove 0x prefix if present
BYTECODE=${BYTECODE#0x}

# WFLOW address on testnet
WFLOW_ADDRESS="0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"

# Encode constructor arguments (address coaAddress, address wflowAddress)
echo "   Constructor arg (COA Address): $COA_ADDRESS"
echo "   Constructor arg (WFLOW Address): $WFLOW_ADDRESS"
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" "$COA_ADDRESS" "$WFLOW_ADDRESS")
CONSTRUCTOR_ARGS=${CONSTRUCTOR_ARGS#0x}

# Append constructor args to bytecode
FULL_BYTECODE="${BYTECODE}${CONSTRUCTOR_ARGS}"

echo "   Bytecode length: ${#FULL_BYTECODE} characters"
echo ""

# Deploy via COA (signed with Google KMS through Cadence)
GAS_LIMIT=10000000

echo "   Deploying via COA (Google KMS signed)..."
DEPLOY_RESULT=$(flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/deploy_evm_contract.cdc" \
    "$FULL_BYTECODE" \
    "$GAS_LIMIT" \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999 \
    --output json)

# Extract the deployed address from the EVM.TransactionExecuted event
# Structure: .events[].values.value.fields[] where name == "contractAddress"
DEPLOYED_ADDRESS=$(echo "$DEPLOY_RESULT" | jq -r '
    .events[] |
    select(.type | contains("EVM.TransactionExecuted")) |
    .values.value.fields[] |
    select(.name == "contractAddress") |
    .value.value
' 2>/dev/null | head -1)

# If extraction failed, show debug info and prompt user
if [ -z "$DEPLOYED_ADDRESS" ] || [ "$DEPLOYED_ADDRESS" == "null" ]; then
    echo ""
    echo "⚠️  Could not automatically extract deployed address from transaction result."
    echo ""
    echo "Transaction result:"
    echo "$DEPLOY_RESULT" | jq . 2>/dev/null || echo "$DEPLOY_RESULT"
    echo ""
    read -p "Enter the deployed contract address (with 0x prefix): " DEPLOYED_ADDRESS
fi

# Ensure 0x prefix
if [[ ! "$DEPLOYED_ADDRESS" =~ ^0x ]]; then
    DEPLOYED_ADDRESS="0x${DEPLOYED_ADDRESS}"
fi

echo ""
echo "📝 Deployed EVM contract address: $DEPLOYED_ADDRESS"
echo ""

# ==========================================
# Step 4: Approve ERC20 tokens for refunds
# ==========================================
echo "🔐 Step 4: Approving ERC20 tokens (WFLOW) for COA refunds..."
echo "   WFLOW Address: $WFLOW_ADDRESS"
echo "   Spender (Contract): $DEPLOYED_ADDRESS"
echo "   Amount: max uint256 (unlimited)"

# Max uint256 for unlimited approval
MAX_UINT256="115792089237316195423570985008687907853269984665640564039457584007913129639935"

flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/approve_erc20_from_coa.cdc" \
    "$WFLOW_ADDRESS" \
    "$DEPLOYED_ADDRESS" \
    "$MAX_UINT256" \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999

echo ""
echo "✅ WFLOW approved for contract to pull refunds from COA"
echo ""

# ==========================================
# Step 5: Deploy Cadence Contracts
# ==========================================
echo "📦 Step 5: Deploying Cadence contracts..."

if ! deploy_or_update_cadence_contract "FlowYieldVaultsEVM" "$PROJECT_ROOT/cadence/contracts/FlowYieldVaultsEVM.cdc"; then
    exit 1
fi

if ! deploy_or_update_cadence_contract "FlowYieldVaultsEVMWorkerOps" "$PROJECT_ROOT/cadence/contracts/FlowYieldVaultsEVMWorkerOps.cdc"; then
    exit 1
fi

echo ""
echo "✅ Cadence contracts deployed"
echo ""

# ==========================================
# Step 6: Ensure Beta Badge + Setup Worker
# ==========================================
echo "🔧 Step 6: Ensuring beta badge and setting up FlowYieldVaultsEVM Worker..."
echo "   FlowYieldVaultsRequests address: $DEPLOYED_ADDRESS"

ensure_beta_badge_for_worker

if flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/setup_worker_with_badge.cdc" \
    "$DEPLOYED_ADDRESS" \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999; then
    echo ""
    echo "✅ Worker initialized and FlowYieldVaultsRequests address set"
else
    echo ""
    echo "⚠️  setup_worker_with_badge failed; attempting rerun-safe address update path..."
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/update_flow_vaults_requests_address.cdc" \
        "$DEPLOYED_ADDRESS" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999

    echo ""
    echo "✅ Existing worker kept; FlowYieldVaultsRequests address updated"
fi

echo ""

# ==========================================
# Step 7: Initialize WorkerOps Handlers & Schedule
# ==========================================
echo "🔧 Step 7: Initializing FlowYieldVaultsEVMWorkerOps handlers and scheduling initial execution..."
echo "   - SchedulerHandler: Recurrent job at fixed interval"
echo "   - WorkerHandler: Processes individual requests"

flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/scheduler/init_and_schedule.cdc" \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999

echo ""
echo "✅ Transaction Handler initialized and initial execution scheduled"
echo ""

# ==========================================
# Step 8: Verify Solidity Contract
# ==========================================

echo "🔍 Step 8: Verifying Solidity contract..."
echo "COA Address (constructor arg): $COA_ADDRESS"
echo "WFLOW Address (constructor arg): $WFLOW_ADDRESS"
echo ""

forge verify-contract \
  --root "$PROJECT_ROOT/solidity" \
  --rpc-url "$TESTNET_RPC_URL" \
  --verifier blockscout \
  --verifier-url 'https://evm-testnet.flowscan.io/api' \
  --skip-is-verified-check \
  --constructor-args $(cast abi-encode "constructor(address,address)" "$COA_ADDRESS" "$WFLOW_ADDRESS") \
  --compiler-version 0.8.20 \
  "$DEPLOYED_ADDRESS" \
  src/FlowYieldVaultsRequests.sol:FlowYieldVaultsRequests

echo ""
echo "✅ Contract verified"
echo ""

# ==========================================
# Step 9: Export Artifacts and Update Addresses
# ==========================================
echo "📦 Step 9: Exporting artifacts and updating contract addresses..."

"$PROJECT_ROOT/scripts/export-artifacts.sh" --network testnet --evm-address "$DEPLOYED_ADDRESS"

echo ""
echo "✅ Artifacts exported and addresses updated"
echo ""

echo "=========================================="
echo "🎉 Full Stack Deployment Complete!"
echo "=========================================="
echo ""
echo "📋 Deployment Summary:"
echo "   EVM Contract: $DEPLOYED_ADDRESS"
echo "   Cadence Contracts: Deployed to testnet-account"
echo "   Worker: Initialized"
echo "   Transaction Handler: Initialized"
echo "   Scheduled Execution: Active (10s delay)"
echo ""
echo "🔗 View EVM Contract:"
echo "   https://evm-testnet.flowscan.io/address/$DEPLOYED_ADDRESS"
echo ""
echo "🔍 Useful Commands:"
echo "   - Check pending requests:"
echo "     flow -f $FLOW_CONFIG_PATH scripts execute cadence/scripts/check_pending_requests.cdc $TESTNET_ACCOUNT_ADDRESS 0 10 --network $FLOW_NETWORK"
echo ""
echo "   - Check handler status:"
echo "     flow -f $FLOW_CONFIG_PATH scripts execute cadence/scripts/check_yieldvaultmanager_status.cdc $TESTNET_ACCOUNT_ADDRESS --network $FLOW_NETWORK"
echo ""
