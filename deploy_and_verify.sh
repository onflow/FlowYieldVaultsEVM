#!/bin/bash

# Deploy and verify FlowYieldVaultsRequests (Solidity) and Cadence contracts
# Run this script from the project root directory
# Uses COA (Cadence Owned Account) for EVM deployment - signed via Google KMS

set -e  # Exit on any error

# Get script directory (project root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables from .env file
set -a
source "$SCRIPT_DIR/.env"
set +a

echo "=========================================="
echo "🚀 Deploying Flow YieldVaults Contracts"
echo "=========================================="
echo ""

# ==========================================
# Step 1: Setup COA (Cadence Owned Account)
# ==========================================
echo "🔑 Step 1: Setting up COA (Cadence Owned Account)..."

flow transactions send "$SCRIPT_DIR/cadence/transactions/setup_coa.cdc" \
    --network testnet \
    --signer testnet-account \
    --compute-limit 9999

# Get the COA address
COA_ADDRESS=$(flow scripts execute "$SCRIPT_DIR/cadence/scripts/get_coa_address.cdc" 0x3abe2e0cbfd02d25 --network testnet --output json | jq -r '.value')

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

flow transactions send "$SCRIPT_DIR/cadence/transactions/deposit_flow_to_coa.cdc" \
    10000.0 \
    --network testnet \
    --signer testnet-account \
    --compute-limit 9999

echo ""
echo "✅ COA funded with 10,000 FLOW"
echo ""

# ==========================================
# Step 3: Build and Deploy EVM Contract via COA
# ==========================================
echo "📦 Step 3: Building and deploying Solidity contract via COA..."

# Build the contract
cd "$SCRIPT_DIR/solidity"
forge build
cd "$SCRIPT_DIR"

# Get the bytecode from the compiled contract
BYTECODE=$(jq -r '.bytecode.object' "$SCRIPT_DIR/solidity/out/FlowYieldVaultsRequests.sol/FlowYieldVaultsRequests.json")

# Remove 0x prefix if present
BYTECODE=${BYTECODE#0x}

# Encode constructor arguments (address coaAddress)
echo "   Constructor arg (COA Address): $COA_ADDRESS"
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address)" "$COA_ADDRESS")
CONSTRUCTOR_ARGS=${CONSTRUCTOR_ARGS#0x}

# Append constructor args to bytecode
FULL_BYTECODE="${BYTECODE}${CONSTRUCTOR_ARGS}"

echo "   Bytecode length: ${#FULL_BYTECODE} characters"
echo ""

# Deploy via COA (signed with Google KMS through Cadence)
GAS_LIMIT=5000000

echo "   Deploying via COA (Google KMS signed)..."
DEPLOY_RESULT=$(flow transactions send "$SCRIPT_DIR/cadence/transactions/deploy_evm_contract.cdc" \
    "$FULL_BYTECODE" \
    "$GAS_LIMIT" \
    --network testnet \
    --signer testnet-account \
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
# Step 4: Deploy Cadence Contracts
# ==========================================
echo "📦 Step 4: Deploying Cadence contracts..."

flow project deploy --update -n testnet

echo ""
echo "✅ Cadence contracts deployed"
echo ""

# ==========================================
# Step 5: Setup FlowYieldVaultsEVM Worker
# ==========================================
echo "🔧 Step 5: Setting up FlowYieldVaultsEVM Worker with Badge..."
echo "   FlowYieldVaultsRequests address: $DEPLOYED_ADDRESS"

flow transactions send "$SCRIPT_DIR/cadence/transactions/setup_worker_with_badge.cdc" \
    "$DEPLOYED_ADDRESS" \
    --network testnet \
    --signer testnet-account \
    --compute-limit 9999

echo ""
echo "✅ Worker initialized and FlowYieldVaultsRequests address set"
echo ""

# ==========================================
# Step 6: Initialize Transaction Handler & Schedule
# ==========================================
echo "🔧 Step 6: Initializing FlowYieldVaultsTransactionHandler and scheduling initial execution..."
echo "   - Delay: 10 seconds"
echo "   - Priority: Calculated dynamically based on execution effort"
echo "   - Execution Effort: Calculated dynamically based on maxRequestsPerTx"

flow transactions send "$SCRIPT_DIR/cadence/transactions/scheduler/init_and_schedule.cdc" \
    10.0 \
    --network testnet \
    --signer testnet-account \
    --compute-limit 9999

echo ""
echo "✅ Transaction Handler initialized and initial execution scheduled"
echo ""

# ==========================================
# Step 7: Verify Solidity Contract
# ==========================================
echo "⏳ Waiting 60 seconds for block explorer to index the deployment..."
sleep 60

echo "🔍 Step 7: Verifying Solidity contract..."
echo "COA Address (constructor arg): $COA_ADDRESS"
echo ""

forge verify-contract \
  --root "$SCRIPT_DIR/solidity" \
  --rpc-url "$TESTNET_RPC_URL" \
  --verifier blockscout \
  --verifier-url 'https://evm-testnet.flowscan.io/api/' \
  --constructor-args $(cast abi-encode "constructor(address)" "$COA_ADDRESS") \
  --compiler-version 0.8.20 \
  "$DEPLOYED_ADDRESS" \
  src/FlowYieldVaultsRequests.sol:FlowYieldVaultsRequests

echo ""
echo "✅ Contract verified"
echo ""

# ==========================================
# Step 8: Export Artifacts and Update Addresses
# ==========================================
echo "📦 Step 8: Exporting artifacts and updating contract addresses..."

"$SCRIPT_DIR/scripts/export-artifacts.sh" --network testnet --evm-address "$DEPLOYED_ADDRESS"

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
echo "     flow scripts execute cadence/scripts/check_pending_requests.cdc 0x3abe2e0cbfd02d25 --network testnet"
echo ""
echo "   - Check handler status:"
echo "     flow scripts execute cadence/scripts/check_yieldvaultmanager_status.cdc 0x3abe2e0cbfd02d25 --network testnet"
echo ""
