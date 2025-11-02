#!/bin/bash

set -e

# Parameters
TIDAL_REQUESTS_CONTRACT=$1
RPC_URL=$2

# Validate parameters
if [ -z "$TIDAL_REQUESTS_CONTRACT" ] || [ -z "$RPC_URL" ]; then
  echo "Error: Missing required parameters"
  echo "Usage: $0 <tidal_requests_contract> <rpc_url>"
  exit 1
fi

echo "=== Deploying contracts ==="

# Deploy TidalRequests Solidity contract
echo "Deploying TidalRequests contract to $RPC_URL..."
forge script ./solidity/script/DeployTidalRequests.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --legacy

echo "✓ Contracts deployed"
echo ""

echo "=== Initializing project ==="

# Deploy Cadence contracts (ignore failures for already-deployed contracts)
echo "Deploying Cadence contracts..."
flow project deploy || echo "⚠️  Some contracts already exist (this is OK)"

# Setup worker with beta badge
echo "Setting up worker with badge for contract $TIDAL_REQUESTS_CONTRACT..."
flow transactions send ./cadence/transactions/setup_worker_with_badge.cdc \
  "$TIDAL_REQUESTS_CONTRACT"

echo "✓ Project initialization complete"