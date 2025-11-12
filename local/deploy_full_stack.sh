#!/bin/bash

set -e  # Exit on any error

# Configuration - Edit these values as needed
DEPLOYER_EOA="0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF"
DEPLOYER_FUNDING="50.46"

USER_A_EOA="0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69"
USER_A_FUNDING="1234.12"

FLOW_VAULTS_REQUESTS_CONTRACT="0x153b84F377C6C7a7D93Bd9a717E48097Ca6Cfd11"

RPC_URL="localhost:8545"

# ============================================
# SETUP ACCOUNTS
# ============================================
echo "=== Setting up accounts ==="

# Fund deployer on EVM side
echo "Funding deployer account ($DEPLOYER_EOA) with $DEPLOYER_FUNDING FLOW..."
flow transactions send ./cadence/transactions/fund_evm_from_coa.cdc \
  "$DEPLOYER_EOA" "$DEPLOYER_FUNDING"

# Fund userA on EVM side
echo "Funding userA account ($USER_A_EOA) with $USER_A_FUNDING FLOW..."
flow transactions send ./cadence/transactions/fund_evm_from_coa.cdc \
  "$USER_A_EOA" "$USER_A_FUNDING"

echo "✓ Accounts setup complete"
echo ""

# ============================================
# DEPLOY CONTRACTS
# ============================================
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

# ============================================
# INITIALIZE PROJECT
# ============================================
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

echo ""
echo "========================================="
echo "✓ Full stack deployment complete!"
echo "========================================="