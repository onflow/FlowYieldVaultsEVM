#!/bin/bash

set -e

# Parameters
FLOW_VAULTS_REQUESTS_CONTRACT=$1
RPC_URL=$2

# Validate parameters
if [ -z "$FLOW_VAULTS_REQUESTS_CONTRACT" ] || [ -z "$RPC_URL" ]; then
  echo "Error: Missing required parameters"
  echo "Usage: $0 <flow_vaults_requests_contract> <rpc_url>"
  exit 1
fi

echo "=== Deploying contracts ==="

# Extract just the address part after "Result: "
COA_ADDRESS=$(flow scripts execute ./cadence/scripts/get_coa_address.cdc 045a1763c93006ca | grep "Result:" | cut -d'"' -f2)

echo "COA Address: $COA_ADDRESS"

# Export for Foundry
export COA_ADDRESS=$COA_ADDRESS

# Deploy FlowVaultsRequests Solidity contract
echo "Deploying FlowVaultsRequests contract to $RPC_URL..."
forge script ./solidity/script/DeployFlowVaultsRequests.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --legacy \
  --optimize \
  --optimizer-runs 1000 \
  --via-ir

echo "✓ Contracts deployed"
echo ""

echo "=== Initializing project ==="

# Deploy Cadence contracts (ignore failures for already-deployed contracts)
echo "Deploying Cadence contracts..."
flow project deploy

# Setup worker with beta badge
echo "Setting up worker with badge for contract $FLOW_VAULTS_REQUESTS_CONTRACT..."
flow transactions send ./cadence/transactions/setup_worker_with_badge.cdc \
  "$FLOW_VAULTS_REQUESTS_CONTRACT" \
  --signer tidal

echo "✓ Project initialization complete"