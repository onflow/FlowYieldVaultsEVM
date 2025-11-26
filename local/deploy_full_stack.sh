#!/bin/bash

set -e  # Exit on any error

# Configuration - Edit these values as needed
# Test accounts derived from simple private keys (for local testing only!)
# Private Key 0x2 -> Deployer
DEPLOYER_EOA="0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF"
DEPLOYER_FUNDING="50.46"

# Private Key 0x3 -> User A (default test user)
USER_A_EOA="0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69"
USER_A_FUNDING="1234.12"

# Private Key 0x4 -> User B
USER_B_EOA="0x1efF47bc3a10a45D4B230B5d10E37751FE6AA718"
USER_B_FUNDING="500.0"

# Private Key 0x5 -> User C
USER_C_EOA="0xe1AB8145F7E55DC933d51a18c793F901A3A0b276"
USER_C_FUNDING="500.0"

# Private Key 0x6 -> User D
USER_D_EOA="0xE57bFE9F44b819898F47BF37E5AF72a0783e1141"
USER_D_FUNDING="500.0"

RPC_URL="localhost:8545"

# ============================================
# VERIFY EVM GATEWAY IS READY
# ============================================
echo "=== Verifying EVM Gateway is ready ==="

MAX_GATEWAY_WAIT=30
GATEWAY_COUNTER=0
while [ $GATEWAY_COUNTER -lt $MAX_GATEWAY_WAIT ]; do
  # Try to connect to EVM Gateway
  GATEWAY_RESPONSE=$(curl -s -X POST http://$RPC_URL \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' || echo "")
  
  if echo "$GATEWAY_RESPONSE" | grep -q "0x"; then
    echo "✓ EVM Gateway is ready and responding"
    break
  fi
  
  echo "Waiting for EVM Gateway to be ready... ($((GATEWAY_COUNTER + 1))/$MAX_GATEWAY_WAIT)"
  sleep 2
  GATEWAY_COUNTER=$((GATEWAY_COUNTER + 1))
done

if [ $GATEWAY_COUNTER -ge $MAX_GATEWAY_WAIT ]; then
  echo "❌ EVM Gateway is not ready after ${MAX_GATEWAY_WAIT} attempts"
  echo "Last response: $GATEWAY_RESPONSE"
  exit 1
fi

# Extra buffer to ensure full readiness
sleep 2

# ============================================
# SETUP ACCOUNTS
# ============================================
echo "=== Setting up accounts ==="

# Fund deployer on EVM side
echo "Funding deployer account ($DEPLOYER_EOA) with $DEPLOYER_FUNDING FLOW..."
flow transactions send ./cadence/transactions/fund_evm_from_coa.cdc \
  "$DEPLOYER_EOA" "$DEPLOYER_FUNDING" --compute-limit 9999

# Fund userA on EVM side
echo "Funding userA account ($USER_A_EOA) with $USER_A_FUNDING FLOW..."
flow transactions send ./cadence/transactions/fund_evm_from_coa.cdc \
  "$USER_A_EOA" "$USER_A_FUNDING" --compute-limit 9999

# Fund userB on EVM side
echo "Funding userB account ($USER_B_EOA) with $USER_B_FUNDING FLOW..."
flow transactions send ./cadence/transactions/fund_evm_from_coa.cdc \
  "$USER_B_EOA" "$USER_B_FUNDING" --compute-limit 9999

# Fund userC on EVM side
echo "Funding userC account ($USER_C_EOA) with $USER_C_FUNDING FLOW..."
flow transactions send ./cadence/transactions/fund_evm_from_coa.cdc \
  "$USER_C_EOA" "$USER_C_FUNDING" --compute-limit 9999

# Fund userD on EVM side
echo "Funding userD account ($USER_D_EOA) with $USER_D_FUNDING FLOW..."
flow transactions send ./cadence/transactions/fund_evm_from_coa.cdc \
  "$USER_D_EOA" "$USER_D_FUNDING" --compute-limit 9999

echo "✓ Accounts setup complete"
echo ""

# ============================================
# DEPLOY CONTRACTS
# ============================================
echo "=== Deploying contracts ==="

# Wait for COA to be available with retry logic
MAX_COA_ATTEMPTS=10
COA_ATTEMPT=0
COA_ADDRESS=""

while [ $COA_ATTEMPT -lt $MAX_COA_ATTEMPTS ]; do
  COA_ADDRESS=$(flow scripts execute ./cadence/scripts/get_coa_address.cdc 045a1763c93006ca 2>/dev/null | grep "Result:" | cut -d'"' -f2 || echo "")
  
  if [ ! -z "$COA_ADDRESS" ]; then
    break
  fi
  
  COA_ATTEMPT=$((COA_ATTEMPT + 1))
  if [ $COA_ATTEMPT -lt $MAX_COA_ATTEMPTS ]; then
    echo "Waiting for COA... ($COA_ATTEMPT/$MAX_COA_ATTEMPTS)"
    sleep 2
  fi
done

if [ -z "$COA_ADDRESS" ]; then
  echo "❌ Failed to get COA address after $MAX_COA_ATTEMPTS attempts"
  exit 1
fi

echo "COA Address: $COA_ADDRESS"

# Export for Foundry
export COA_ADDRESS=$COA_ADDRESS

# Verify EVM Gateway one more time before Solidity deployment
echo "Final EVM Gateway verification before deployment..."
FINAL_CHECK=$(curl -s -X POST http://$RPC_URL \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' || echo "")

if ! echo "$FINAL_CHECK" | grep -q "result"; then
  echo "❌ EVM Gateway not responding properly before deployment"
  echo "Response: $FINAL_CHECK"
  exit 1
fi

echo "✓ EVM Gateway confirmed ready for deployment"

# Deploy FlowVaultsRequests Solidity contract
echo "Deploying FlowVaultsRequests contract to $RPC_URL..."
DEPLOYMENT_OUTPUT=$(forge script ./solidity/script/DeployFlowVaultsRequests.s.sol \
  --root ./solidity \
  --rpc-url "http://$RPC_URL" \
  --broadcast \
  --legacy 2>&1)

echo "$DEPLOYMENT_OUTPUT"

# Extract the deployed contract address from the output
FLOW_VAULTS_REQUESTS_CONTRACT=$(echo "$DEPLOYMENT_OUTPUT" | grep "FlowVaultsRequests deployed at:" | sed 's/.*: //')

if [ -z "$FLOW_VAULTS_REQUESTS_CONTRACT" ]; then
  echo "❌ Failed to extract FlowVaultsRequests contract address from deployment"
  exit 1
fi

echo "✓ FlowVaultsRequests contract deployed at: $FLOW_VAULTS_REQUESTS_CONTRACT"
echo ""

# ============================================
# INITIALIZE PROJECT
# ============================================
echo "=== Initializing project ==="

# Deploy Cadence contracts (ignore failures for already-deployed contracts)
echo "Deploying Cadence contracts..."
flow project deploy || echo "⚠ Some contracts may already be deployed, continuing..."

# Setup worker with beta badge
echo "Setting up worker with badge for contract $FLOW_VAULTS_REQUESTS_CONTRACT..."
flow transactions send ./cadence/transactions/setup_worker_with_badge.cdc \
  "$FLOW_VAULTS_REQUESTS_CONTRACT" \
  --signer tidal --compute-limit 9999

echo "✓ Project initialization complete"

echo ""
echo "========================================="
echo "✓ Full stack deployment complete!"
echo "========================================="
echo ""
echo "FlowVaultsRequests Contract: $FLOW_VAULTS_REQUESTS_CONTRACT"
echo ""
echo "Export this for use in other scripts:"
echo "export FLOW_VAULTS_REQUESTS_CONTRACT=$FLOW_VAULTS_REQUESTS_CONTRACT"