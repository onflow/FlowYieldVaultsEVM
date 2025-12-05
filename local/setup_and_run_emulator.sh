#!/bin/bash

set -e  # Exit on any error

# install Flow YieldVaults submodule as dependency
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

# ============================================
# FLOW-YIELD-VAULTS SETUP (using univ3_test pattern)
# ============================================
echo "Setting up FlowYieldVaults environment..."
cd ./lib/FlowYieldVaults

# Start Flow Emulator (runs in background)
./local/run_emulator.sh

# Setup wallets (creates test accounts)
./local/setup_wallets.sh

# Start EVM Gateway (runs in background)
./local/run_evm_gateway.sh

echo "Setup PunchSwap"
./local/punchswap/setup_punchswap.sh
./local/punchswap/e2e_punchswap.sh

echo "Setup emulator"
./local/setup_emulator.sh

# Bridge tokens (MOET, USDC, WBTC) and setup liquidity pools
./local/setup_bridged_tokens.sh

cd ../..

echo ""
echo "========================================="
echo "✓ Flow Emulator & EVM Gateway are running"
echo "✓ FlowYieldVaults with TracerStrategy configured"
echo "✓ Ready for FlowYieldVaultsEVM deployment"
echo "========================================="