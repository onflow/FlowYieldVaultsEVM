#!/bin/bash

set -e  # Exit on any error

# install Flow Vaults submodule as dependency
git submodule update --init --recursive

# ============================================
# CLEANUP SECTION - All cleanup operations
# ============================================
echo "Starting cleanup process..."

# 1. Kill any existing processes on required ports
echo "Killing existing processes on ports..."
lsof -ti :8080 | xargs kill -9 2>/dev/null || true
lsof -ti :8545 | xargs kill -9 2>/dev/null || true
lsof -ti :3569 | xargs kill -9 2>/dev/null || true
lsof -ti :8888 | xargs kill -9 2>/dev/null || true

# Brief pause to ensure ports are released
sleep 2

# 2. Clean the db directory (only if it exists)
echo "Cleaning ./db directory..."
if [ -d "./db" ]; then
  rm -rf ./db/*
  echo "Database directory cleaned."
else
  echo "Database directory does not exist, skipping..."
fi

# 3. Clean the imports directory
echo "Cleaning ./imports directory..."
if [ -d "./imports" ]; then
  rm -rf ./imports/*
  echo "Imports directory cleaned."
else
  echo "Imports directory does not exist, creating it..."
  mkdir -p ./imports
fi

echo "Cleanup completed!"
echo ""
# ============================================
# END CLEANUP SECTION
# ============================================

# Install dependencies - auto-answer yes to all prompts
echo "Installing Flow dependencies..."
flow deps install --skip-alias --skip-deployments

# Start Flow Emulator in background
echo "Starting Flow Emulator..."
flow emulator &
EMULATOR_PID=$!
echo "Emulator PID: $EMULATOR_PID"

# Wait for emulator to be ready
echo "Waiting for Flow Emulator to be ready..."
MAX_WAIT=30
COUNTER=0
until curl -s http://localhost:8888/health > /dev/null 2>&1; do
  if [ $COUNTER -ge $MAX_WAIT ]; then
    echo "ERROR: Flow Emulator failed to start within ${MAX_WAIT} seconds"
    kill $EMULATOR_PID 2>/dev/null || true
    exit 1
  fi
  echo "Waiting for emulator... ($COUNTER/$MAX_WAIT)"
  sleep 1
  COUNTER=$((COUNTER + 1))
done
echo "✓ Flow Emulator is ready!"

# ============================================
# FLOW-VAULTS-SC SETUP (with TracerStrategy)
# ============================================
echo "Setting up flow-vaults-sc environment..."
cd ./lib/flow-vaults-sc

# Install flow-vaults-sc dependencies
echo "Installing flow-vaults-sc dependencies..."

# Setup wallets (creates test accounts)
echo "Setting up wallets and test accounts..."
./local/setup_wallets.sh

# Deploy and configure FlowVaults with TracerStrategy
echo "Deploying FlowVaults contracts and configuring TracerStrategy..."
./local/setup_emulator.sh

# Register tokens in the Flow EVM Bridge
echo "Registering tokens in bridge..."
echo "- Registering MOET..."
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc \
  "A.045a1763c93006ca.MOET.Vault" \
  --gas-limit 9999 \
  --signer tidal

echo "- Registering YieldToken..."
flow transactions send ./lib/flow-evm-bridge/cadence/transactions/bridge/onboarding/onboard_by_type_identifier.cdc \
  "A.045a1763c93006ca.YieldToken.Vault" \
  --gas-limit 9999 \
  --signer tidal

echo "✓ Tokens registered in bridge"

cd ../..

# Start EVM Gateway in background AFTER all contracts are deployed and accounts created
echo "Starting EVM Gateway..."
EMULATOR_COINBASE=FACF71692421039876a5BB4F10EF7A439D8ef61E
EMULATOR_COA_ADDRESS=e03daebed8ca0615
EMULATOR_COA_KEY=$(cat ./lib/flow-vaults-sc/local/evm-gateway.pkey)
RPC_PORT=8545

flow evm gateway \
  --flow-network-id=emulator \
  --evm-network-id=preview \
  --coinbase=$EMULATOR_COINBASE \
  --coa-address=$EMULATOR_COA_ADDRESS \
  --coa-key=$EMULATOR_COA_KEY \
  --gas-price=0 \
  --rpc-port $RPC_PORT &
GATEWAY_PID=$!
echo "EVM Gateway PID: $GATEWAY_PID"

# Wait for EVM Gateway to be ready - Phase 1: Basic RPC response
echo "Waiting for EVM Gateway RPC to respond..."
MAX_WAIT=60
COUNTER=0
until curl -s -X POST http://localhost:$RPC_PORT \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -q "result"; do
  if [ $COUNTER -ge $MAX_WAIT ]; then
    echo "ERROR: EVM Gateway failed to start within ${MAX_WAIT} seconds"
    kill $GATEWAY_PID 2>/dev/null || true
    kill $EMULATOR_PID 2>/dev/null || true
    exit 1
  fi
  echo "Waiting for EVM Gateway RPC... ($COUNTER/$MAX_WAIT)"
  sleep 1
  COUNTER=$((COUNTER + 1))
done
echo "✓ EVM Gateway RPC is responding"

# Wait for EVM Gateway to be ready - Phase 2: Full initialization
echo "Verifying EVM Gateway full initialization..."
COUNTER=0
until curl -s -X POST http://localhost:$RPC_PORT \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' | grep -q "0x"; do
  if [ $COUNTER -ge 30 ]; then
    echo "ERROR: EVM Gateway not fully initialized within 30 seconds"
    kill $GATEWAY_PID 2>/dev/null || true
    kill $EMULATOR_PID 2>/dev/null || true
    exit 1
  fi
  echo "Waiting for full initialization... ($COUNTER/30)"
  sleep 1
  COUNTER=$((COUNTER + 1))
done

# Give it a couple more seconds to settle completely
echo "Allowing EVM Gateway to settle..."
sleep 3
echo "✓ EVM Gateway is fully ready!"

echo ""
echo "========================================="
echo "✓ Flow Emulator & EVM Gateway are running"
echo "✓ FlowVaults with TracerStrategy configured"
echo "✓ Ready for FlowVaultsEVM deployment"
echo "========================================="