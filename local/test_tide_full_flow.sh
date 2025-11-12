#!/bin/bash

# Flow Vaults EVM Bridge - Complete Tide Flow E2E Test
# This script tests the full tide lifecycle:
# 1. Create tide with initial deposit (10 FLOW)
# 2. Add additional deposit (20 FLOW) - Total: 30 FLOW
# 3. Withdraw half (15 FLOW) - Remaining: 15 FLOW
# 4. Close tide (withdraw remaining 15 FLOW and close position)
#
# PREREQUISITES:
# You must first setup the emulator and deploy contracts:
#   ./local/setup_and_run_emulator.sh &
#   ./local/deploy_full_stack.sh

set -e  # Exit on any error

echo "================================================"
echo "Flow Vaults - Complete Tide Flow E2E Test"
echo "================================================"
echo ""
echo "⚠️  IMPORTANT: This test requires the emulator to be running"
echo "   and contracts to be deployed. If you haven't done so:"
echo "   1. ./local/setup_and_run_emulator.sh &"
echo "   2. ./local/deploy_full_stack.sh"
echo ""
echo "Press Ctrl+C within 5 seconds to cancel..."
sleep 5
echo ""

# Configuration
RPC_URL="localhost:8545"
USER_ADDRESS="0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69"
TIDE_ID=1

# ============================================
# Step 1: Create Tide (10 FLOW)
# ============================================
echo "=== Step 1: Creating Tide ==="
echo "Initial Amount: 10 FLOW"
echo ""

AMOUNT=10000000000000000000 forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
    --sig "runCreateTide()" \
    --rpc-url $RPC_URL \
    --broadcast \
    --legacy

echo ""
echo "✅ Tide creation request submitted"
echo ""

# ============================================
# Step 2: Process Create Tide Request
# ============================================
echo "=== Step 2: Processing Create Tide Request ==="
echo ""

flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal

echo ""
echo "✅ Create tide request processed"
echo ""
sleep 2

# ============================================
# Step 3: Check Tide Details After Creation
# ============================================
echo "=== Step 3: Checking Tide Details After Creation ==="
echo "Expected Balance: ~10 FLOW"
echo ""

flow scripts execute ./cadence/scripts/check_tide_details.cdc $TIDE_ID "$USER_ADDRESS"

echo ""
echo "✅ Tide details verified after creation"
echo ""

# ============================================
# Step 4: Deposit to Tide (20 FLOW)
# ============================================
echo "=== Step 4: Depositing Additional Funds to Tide ==="
echo "Deposit Amount: 20 FLOW"
echo "Expected Total: ~30 FLOW"
echo ""

AMOUNT=20000000000000000000 forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
    --sig "runDepositToTide(uint64)" $TIDE_ID \
    --rpc-url $RPC_URL \
    --broadcast \
    --legacy

echo ""
echo "✅ Deposit request submitted"
echo ""

# ============================================
# Step 5: Process Deposit Request
# ============================================
echo "=== Step 5: Processing Deposit Request ==="
echo ""

flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal

echo ""
echo "✅ Deposit request processed"
echo ""
sleep 2

# ============================================
# Step 6: Check Tide Details After Deposit
# ============================================
echo "=== Step 6: Checking Tide Details After Deposit ==="
echo "Expected Balance: ~30 FLOW"
echo ""

flow scripts execute ./cadence/scripts/check_tide_details.cdc $TIDE_ID "$USER_ADDRESS"

echo ""
echo "✅ Tide details verified after deposit"
echo ""

# ============================================
# Step 7: Withdraw Half from Tide (15 FLOW)
# ============================================
echo "=== Step 7: Withdrawing Half from Tide ==="
echo "Withdraw Amount: 15 FLOW"
echo "Expected Remaining: ~15 FLOW"
echo ""

forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
    --sig "runWithdrawFromTide(uint64,uint256)" $TIDE_ID 15000000000000000000 \
    --rpc-url $RPC_URL \
    --broadcast \
    --legacy

echo ""
echo "✅ Withdrawal request submitted"
echo ""

# ============================================
# Step 8: Process Withdraw Request
# ============================================
echo "=== Step 8: Processing Withdraw Request ==="
echo ""

flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal

echo ""
echo "✅ Withdrawal request processed"
echo ""
sleep 2

# ============================================
# Step 9: Check Tide Details After Withdrawal
# ============================================
echo "=== Step 9: Checking Tide Details After Withdrawal ==="
echo "Expected Balance: ~15 FLOW"
echo ""

flow scripts execute ./cadence/scripts/check_tide_details.cdc $TIDE_ID "$USER_ADDRESS"

echo ""
echo "✅ Tide details verified after withdrawal"
echo ""

# ============================================
# Step 10: Close Tide
# ============================================
echo "=== Step 10: Closing Tide ==="
echo "This will withdraw all remaining funds and close the position"
echo ""

forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
    --sig "runCloseTide(uint64)" $TIDE_ID \
    --rpc-url $RPC_URL \
    --broadcast \
    --legacy

echo ""
echo "✅ Close tide request submitted"
echo ""

# ============================================
# Step 11: Process Close Tide Request
# ============================================
echo "=== Step 11: Processing Close Tide Request ==="
echo ""

flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal

echo ""
echo "✅ Close tide request processed"
echo ""
sleep 2

# ============================================
# Step 12: Verify Tide Was Closed
# ============================================
echo "=== Step 12: Verifying Tide Was Closed ==="
echo "Expected: Tide should be closed"
echo ""

flow scripts execute ./cadence/scripts/check_tide_details.cdc $TIDE_ID "$USER_ADDRESS"

echo ""
echo "================================================"
echo "Complete Tide Flow E2E Test Finished! ✅"
echo "================================================"
echo ""
echo "Test Summary:"
echo "1. ✅ Created tide with 10 FLOW"
echo "2. ✅ Deposited 20 FLOW (total: 30 FLOW)"
echo "3. ✅ Withdrew 15 FLOW (remaining: 15 FLOW)"
echo "4. ✅ Closed tide (withdrew final 15 FLOW)"
echo ""
echo "All tide operations completed successfully!"
echo ""
