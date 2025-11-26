#!/bin/bash

# Full Stack Deployment and Setup Script for Flow Testnet
# This script:
# 1. Deploys Solidity contracts (FlowVaultsRequests)
# 2. Deploys Cadence contracts (FlowVaultsEVM, FlowVaultsTransactionHandler)
# 3. Updates FlowVaultsEVM with the deployed contract address
# 4. Initializes the transaction handler
# 5. Schedules the first automated execution

set -e  # Exit on any error

echo "=========================================="
echo "🚀 Flow Vaults Full Stack Deployment"
echo "   Network: Flow Testnet"
echo "=========================================="
echo ""

# ==========================================
# Step 1: Deploy Solidity Contract
# ==========================================
echo "📦 Step 1: Deploying Solidity contracts..."
cd solidity
./script/deploy_and_verify.sh
cd ..

# Extract deployed contract address from broadcast file
DEPLOYED_ADDRESS=$(jq -r '.transactions[0].contractAddress' solidity/broadcast/DeployFlowVaultsRequests.s.sol/545/run-latest.json)

if [ -z "$DEPLOYED_ADDRESS" ] || [ "$DEPLOYED_ADDRESS" == "null" ]; then
    echo "❌ Error: Could not find deployed contract address"
    exit 1
fi

echo ""
echo "✅ FlowVaultsRequests deployed at: $DEPLOYED_ADDRESS"
echo ""

# ==========================================
# Step 2: Deploy Cadence Contracts
# ==========================================
echo "📦 Step 2: Deploying Cadence contracts..."
flow project deploy -n=testnet --update

echo ""
echo "✅ Cadence contracts deployed"
echo ""

# ==========================================
# Step 3: Setup Worker with Badge
# ==========================================
echo "🔧 Step 3: Setting up Worker with Beta Badge and FlowVaultsRequests address..."
flow transactions send cadence/transactions/setup_worker_with_badge.cdc \
    $DEPLOYED_ADDRESS \
    --network testnet \
    --signer testnet-account --compute-limit 9999

echo ""
echo "✅ Worker initialized and FlowVaultsRequests address set"
echo ""

# ==========================================
# Step 4: Initialize Transaction Handler
# ==========================================
echo "🔧 Step 4: Initializing FlowVaultsTransactionHandler..."
flow transactions send cadence/transactions/init_flow_vaults_transaction_handler.cdc \
    --network testnet \
    --signer testnet-account --compute-limit 9999

echo ""
echo "✅ Transaction Handler initialized"
echo ""

# ==========================================
# Step 5: Schedule Initial Execution
# ==========================================
echo "⏰ Step 5: Scheduling initial automated execution..."
echo "   - Delay: 10 seconds"
echo "   - Priority: Medium (1)"
echo "   - Execution Effort: 7499"

flow transactions send cadence/transactions/schedule_initial_flow_vaults_execution.cdc \
    10.0 1 7499 \
    --network testnet \
    --signer testnet-account --compute-limit 9999

echo ""
echo "✅ Initial execution scheduled"
echo ""

# ==========================================
# Deployment Summary
# ==========================================
echo "=========================================="
echo "🎉 Full Stack Deployment Complete!"
echo "=========================================="
echo ""
echo "📋 Deployment Summary:"
echo "   EVM Contract: $DEPLOYED_ADDRESS"
echo "   Cadence Contracts: Deployed to testnet-account"
echo "   Transaction Handler: Initialized"
echo "   Scheduled Execution: Active (60s delay)"
echo ""
echo "🔗 View EVM Contract:"
echo "   https://evm-testnet.flowscan.io/address/$DEPLOYED_ADDRESS"
echo ""
echo "📝 Next Steps:"
echo "   1. Monitor transaction handler execution"
echo "   2. Check pending requests processing"
echo "   3. Verify automated scheduling is working"
echo ""
echo "🔍 Useful Commands:"
echo "   - Check pending requests:"
echo "     flow scripts execute cadence/scripts/check_pending_requests.cdc --network testnet"
echo ""
echo "   - Check handler status:"
echo "     flow scripts execute cadence/scripts/check_tidemanager_status.cdc --network testnet"
echo ""
