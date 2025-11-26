#!/bin/bash

# Flow Vaults EVM Bridge - Scheduled Transaction Setup
# This script initializes the transaction handler and schedules the first execution

set -e  # Exit on any error

echo "================================================"
echo "Flow Vaults EVM Bridge - Scheduled Txn Setup"
echo "================================================"
echo ""

# Step 1: Initialize the Transaction Handler
echo "Step 1: Initializing Transaction Handler..."
flow transactions send ./cadence/transactions/init_flow_vaults_transaction_handler.cdc \
    --signer tidal --compute-limit 9999

echo "✅ Transaction Handler initialized"
echo ""

# Step 2: Schedule Initial Execution
echo "Step 2: Scheduling initial execution..."
echo "Parameters:"
echo "  - Delay: 3 seconds"
echo "  - Priority: Medium (1)"
echo "  - Execution Effort: 6000"
echo ""

flow transactions send ./cadence/transactions/schedule_initial_flow_vaults_execution.cdc \
    --args-json '[
        {"type":"UFix64","value":"3.0"},
        {"type":"UInt8","value":"1"},
        {"type":"UInt64","value":"6000"}
    ]' \
    --signer tidal --compute-limit 9999

echo "✅ Initial execution scheduled"
echo ""
echo "================================================"
echo "Setup Complete!"
echo "================================================"
echo ""
echo "The FlowVaultsEVM worker will process requests in 10 seconds."
echo "After that, it will need to be rescheduled manually or implement"
echo "self-scheduling logic."
echo ""