#!/bin/bash

# Deploy and verify FlowYieldVaultsRequests (Solidity) and Cadence contracts
# Run this script from the project root directory

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
# Step 1: Deploy Solidity Contract
# ==========================================
echo "📦 Step 1: Deploying Solidity contract (FlowYieldVaultsRequests)..."

forge script "$SCRIPT_DIR/solidity/script/DeployFlowYieldVaultsRequests.s.sol:DeployFlowYieldVaultsRequests" \
    --root "$SCRIPT_DIR/solidity" \
    --rpc-url "$TESTNET_RPC_URL" \
    --broadcast \
    -vvvv

# Extract the deployed contract address from the broadcast file
DEPLOYED_ADDRESS=$(jq -r '.transactions[0].contractAddress' "$SCRIPT_DIR/solidity/broadcast/DeployFlowYieldVaultsRequests.s.sol/545/run-latest.json")

if [ -z "$DEPLOYED_ADDRESS" ] || [ "$DEPLOYED_ADDRESS" == "null" ]; then
    echo "❌ Error: Could not find deployed contract address"
    exit 1
fi

echo ""
echo "📝 Deployed EVM contract address: $DEPLOYED_ADDRESS"
echo ""

# ==========================================
# Step 2: Deploy Cadence Contracts
# ==========================================
echo "📦 Step 2: Deploying Cadence contracts..."

flow project deploy --update -n testnet -signer testnet-account

echo ""
echo "✅ Cadence contracts deployed"
echo ""

# ==========================================
# Step 3: Setup FlowYieldVaultsEVM Worker
# ==========================================
echo "🔧 Step 3: Setting up FlowYieldVaultsEVM Worker with Badge..."
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
# Step 4: Initialize Transaction Handler & Schedule
# ==========================================
echo "🔧 Step 4: Initializing FlowYieldVaultsTransactionHandler and scheduling initial execution..."
echo "   - Delay: 10 seconds"
echo "   - Priority: High (0)"
echo "   - Execution Effort: 9999"

flow transactions send "$SCRIPT_DIR/cadence/transactions/scheduler/init_and_schedule.cdc" \
    10.0 0 9999 \
    --network testnet \
    --signer testnet-account \
    --compute-limit 9999

echo ""
echo "✅ Transaction Handler initialized and initial execution scheduled"
echo ""

# ==========================================
# Step 5: Verify Solidity Contract
# ==========================================
echo "⏳ Waiting 60 seconds for block explorer to index the deployment..."
sleep 60

echo "🔍 Step 5: Verifying Solidity contract..."
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
echo "     flow scripts execute cadence/scripts/check_pending_requests.cdc 0x4135b56ffc55ecef --network testnet"
echo ""
echo "   - Check handler status:"
echo "     flow scripts execute cadence/scripts/check_yieldvaultmanager_status.cdc 0x4135b56ffc55ecef --network testnet"
echo ""
