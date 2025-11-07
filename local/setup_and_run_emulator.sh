#!/bin/bash

# install Flow Vaults submodule as dependency
git submodule update --init --recursive -f

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

# 2. Clean the db directory
echo "Cleaning ./db directory..."
if [ -d "./db" ]; then
  rm -rf ./db/*
  echo "Database directory cleaned."
else
  echo "Database directory does not exist, creating it..."
  mkdir -p ./db
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

# Define addresses and ports as variables
COA_ADDRESS="${COA_ADDRESS:-0xf8d6e0586b0a20c7}"
COA_KEY="${COA_KEY:-b1a77d1b931e602dda3d70e6dcddbd8692b55940cc33a46c4e264b1d7415dd4f}"
COINBASE_EOA="${COINBASE_EOA:-0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf}"
DEPLOYER_EOA="${DEPLOYER_EOA:-0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF}"
USER_A_EOA="${USER_A_EOA:-0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69}"
FLOW_VAULTS_REQUESTS_CONTRACT="${FLOW_VAULTS_REQUESTS_CONTRACT:-0x153b84F377C6C7a7D93Bd9a717E48097Ca6Cfd11}"
EMULATOR_PORT="${EMULATOR_PORT:-8080}"
RPC_PORT="${RPC_PORT:-8545}"

# Install dependencies - auto-answer yes to all prompts
echo "Installing Flow dependencies..."
yes | flow deps install

# Start Flow emulator in the background
flow emulator &

# Wait for emulator port to be available
echo "Waiting for port $EMULATOR_PORT to be ready..."
while ! nc -z localhost $EMULATOR_PORT; do
  sleep 1
done

echo "Port $EMULATOR_PORT is ready!"

# Start Flow EVM gateway
echo "Starting Flow EVM gateway on RPC port $RPC_PORT..."
flow evm gateway --coa-address $COA_ADDRESS \
                 --coa-key $COA_KEY \
                 --coa-resource-create \
                 --coinbase $COINBASE_EOA \
                 --rpc-port $RPC_PORT \
                 --evm-network-id preview &

# Display account information
echo ""
echo "=== Account Information ==="
echo "coinbase (EOA): $COINBASE_EOA"
echo "deployer (EOA): $DEPLOYER_EOA"
echo "userA (EOA): $USER_A_EOA"
echo "FlowVaultsRequests contract: $FLOW_VAULTS_REQUESTS_CONTRACT"
echo "RPC Port: $RPC_PORT"
echo "=========================="

# Run the flow-vaults-sc setup script in its directory
echo ""
echo "Running flow-vaults-sc setup script..."
cd ./lib/flow-vaults-sc
./local/setup_wallets.sh
./local/setup_emulator.sh
cd ../..