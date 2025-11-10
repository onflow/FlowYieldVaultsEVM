#!/bin/bash

set -e

# Parameters
DEPLOYER_EOA=$1
DEPLOYER_FUNDING=$2
USER_A_EOA=$3
USER_A_FUNDING=$4

# Validate parameters
if [ -z "$DEPLOYER_EOA" ] || [ -z "$DEPLOYER_FUNDING" ] || [ -z "$USER_A_EOA" ] || [ -z "$USER_A_FUNDING" ]; then
  echo "Error: Missing required parameters"
  echo "Usage: $0 <deployer_eoa> <deployer_funding> <user_a_eoa> <user_a_funding>"
  exit 1
fi

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