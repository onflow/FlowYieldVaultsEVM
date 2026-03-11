#!/bin/bash

# Mainnet-only scheduler configuration tuning flow.
# Applies the tuned execution-effort values plus wakeup/max-processing overrides.
# Optionally restarts the scheduler so the new wakeup interval takes effect immediately.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

FLOW_CONFIG_PATH="$PROJECT_ROOT/flow.json"
FLOW_NETWORK="mainnet"
FLOW_SIGNER="${FLOW_SIGNER:-mainnet-account}"
FLOW_ACCOUNT_ADDRESS="${FLOW_ACCOUNT_ADDRESS:-a7d9a1bece1378a3}"
FLOW_ACCOUNT_ADDRESS="${FLOW_ACCOUNT_ADDRESS#0x}"
FLOW_ACCOUNT_ADDRESS="${FLOW_ACCOUNT_ADDRESS#0X}"
FLOW_ACCOUNT_ADDRESS_HEX="0x${FLOW_ACCOUNT_ADDRESS}"

SCHEDULER_BASE_EFFORT="${SCHEDULER_BASE_EFFORT:-950}"
SCHEDULER_PER_REQUEST_EFFORT="${SCHEDULER_PER_REQUEST_EFFORT:-250}"
SCHEDULER_WAKEUP_INTERVAL="${SCHEDULER_WAKEUP_INTERVAL:-10.0}"
MAX_PROCESSING_REQUESTS="${MAX_PROCESSING_REQUESTS:-10}"
WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT="${WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT:-6000}"
WORKER_DEPOSIT_REQUEST_EFFORT="${WORKER_DEPOSIT_REQUEST_EFFORT:-1500}"
WORKER_WITHDRAW_REQUEST_EFFORT="${WORKER_WITHDRAW_REQUEST_EFFORT:-3000}"
WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT="${WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT:-4500}"
RESCHEDULE_IMMEDIATELY="${RESCHEDULE_IMMEDIATELY:-0}"

flow_cmd() {
    flow -f "$FLOW_CONFIG_PATH" "$@"
}

bool_is_true() {
    case "${1,,}" in
        1|true|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}

set_execution_effort_constant() {
    local key="$1"
    local value="$2"

    echo "   - Setting $key = $value"
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/set_execution_effort_constant.cdc" \
        "$key" \
        "$value" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999
}

set_scheduler_wakeup_interval() {
    local value="$1"

    echo "   - Setting schedulerWakeupInterval = $value"
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/set_scheduler_wakeup_interval.cdc" \
        "$value" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999
}

set_max_processing_requests() {
    local value="$1"

    echo "   - Setting maxProcessingRequests = $value"
    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/set_max_processing_requests.cdc" \
        "$value" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999
}

restart_scheduler_now() {
    echo ""
    echo "⚠️  Immediate reschedule requested."
    echo "   This cancels the currently scheduled scheduler transaction and any tracked in-flight worker transactions."
    echo ""

    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/scheduler/stop_all_scheduled_transactions.cdc" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999

    flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/scheduler/unpause_transaction_handler.cdc" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" \
        --compute-limit 9999
}

echo "=========================================="
echo "🚀 Mainnet Scheduler Config Update"
echo "=========================================="
echo "Network:            $FLOW_NETWORK"
echo "Signer:             $FLOW_SIGNER ($FLOW_ACCOUNT_ADDRESS_HEX)"
echo "schedulerBaseEffort $SCHEDULER_BASE_EFFORT"
echo "schedulerPerRequest $SCHEDULER_PER_REQUEST_EFFORT"
echo "schedulerWakeup     $SCHEDULER_WAKEUP_INTERVAL seconds"
echo "maxProcessing       $MAX_PROCESSING_REQUESTS"
echo "workerCreateEffort  $WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT"
echo "workerDepositEffort $WORKER_DEPOSIT_REQUEST_EFFORT"
echo "workerWithdrawEffort $WORKER_WITHDRAW_REQUEST_EFFORT"
echo "workerCloseEffort   $WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT"
echo "rescheduleNow       $RESCHEDULE_IMMEDIATELY"
echo ""

echo "⚙️  Step 1: Applying scheduler configuration..."

set_execution_effort_constant "schedulerBaseEffort" "$SCHEDULER_BASE_EFFORT"
set_execution_effort_constant "schedulerPerRequestEffort" "$SCHEDULER_PER_REQUEST_EFFORT"
set_execution_effort_constant "workerCreateYieldVaultRequestEffort" "$WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT"
set_execution_effort_constant "workerDepositRequestEffort" "$WORKER_DEPOSIT_REQUEST_EFFORT"
set_execution_effort_constant "workerWithdrawRequestEffort" "$WORKER_WITHDRAW_REQUEST_EFFORT"
set_execution_effort_constant "workerCloseYieldVaultRequestEffort" "$WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT"
set_scheduler_wakeup_interval "$SCHEDULER_WAKEUP_INTERVAL"
set_max_processing_requests "$MAX_PROCESSING_REQUESTS"

echo ""
echo "✅ Scheduler configuration applied"

if bool_is_true "$RESCHEDULE_IMMEDIATELY"; then
    restart_scheduler_now
    echo ""
    echo "✅ Scheduler restarted with the new settings"
else
    echo ""
    echo "ℹ️  The new wakeup interval will take effect after the next already-scheduled scheduler run re-schedules itself."
fi

echo ""
echo "=========================================="
echo "✅ Mainnet Scheduler Update Complete"
echo "=========================================="
echo ""
echo "Applied values:"
echo "   schedulerBaseEffort:   $SCHEDULER_BASE_EFFORT"
echo "   schedulerPerRequest:   $SCHEDULER_PER_REQUEST_EFFORT"
echo "   workerCreateEffort:    $WORKER_CREATE_YIELDVAULT_REQUEST_EFFORT"
echo "   workerDepositEffort:   $WORKER_DEPOSIT_REQUEST_EFFORT"
echo "   workerWithdrawEffort:  $WORKER_WITHDRAW_REQUEST_EFFORT"
echo "   workerCloseEffort:     $WORKER_CLOSE_YIELDVAULT_REQUEST_EFFORT"
echo "   schedulerWakeup:       $SCHEDULER_WAKEUP_INTERVAL seconds"
echo "   maxProcessingRequests: $MAX_PROCESSING_REQUESTS"
echo "   rescheduleNow:         $RESCHEDULE_IMMEDIATELY"
echo ""
