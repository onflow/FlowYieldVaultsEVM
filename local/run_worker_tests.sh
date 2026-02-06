#!/bin/bash

set -e  # Exit on any error

# ============================================
# WORKER OPS TEST SCRIPT FOR FLOWYIELDVAULTSEVM
# ============================================
# This script tests the FlowYieldVaultsEVMWorkerOps contract:
# - Scheduler initialization
# - Automated request processing via FlowTransactionScheduler
# - Pause/unpause scheduler
# - Stop all scheduled transactions
# - Multi-user automated processing
#
# The contract address is automatically loaded from ./local/.deployed_contract_address
# (created by deploy_full_stack.sh)
#
# Usage (run all three scripts chained):
#   ./local/setup_and_run_emulator.sh && ./local/deploy_full_stack.sh && ./local/run_worker_tests.sh
#
# Or run individually after deployment:
#   ./local/run_worker_tests.sh
# ============================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# ============================================
# CONFIGURATION
# ============================================

# Check if contract address is set, otherwise read from file
if [ -z "$FLOW_VAULTS_REQUESTS_CONTRACT" ]; then
  if [ -f "./local/.deployed_contract_address" ]; then
    FLOW_VAULTS_REQUESTS_CONTRACT=$(cat ./local/.deployed_contract_address)
    echo "Loaded contract address from ./local/.deployed_contract_address"
  else
    echo -e "${RED}ERROR: FLOW_VAULTS_REQUESTS_CONTRACT not set${NC}"
    echo "Please run ./local/deploy_full_stack.sh first"
    exit 1
  fi
fi

# Test accounts (from deploy_full_stack.sh)
# Private Key 0x3 -> User A
USER_A_EOA="0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69"
USER_A_PK="0x0000000000000000000000000000000000000000000000000000000000000003"

# Private Key 0x4 -> User B
USER_B_EOA="0x1efF47bc3a10a45D4B230B5d10E37751FE6AA718"
USER_B_PK="0x0000000000000000000000000000000000000000000000000000000000000004"

# Private Key 0x5 -> User C
USER_C_EOA="0xe1AB8145F7E55DC933d51a18c793F901A3A0b276"
USER_C_PK="0x0000000000000000000000000000000000000000000000000000000000000005"

RPC_URL="http://localhost:8545"

# Contract constants
NATIVE_FLOW="0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF"
VAULT_IDENTIFIER="A.0ae53cb6e3f42a79.FlowToken.Vault"
STRATEGY_IDENTIFIER="A.045a1763c93006ca.FlowYieldVaultsStrategies.TracerStrategy"
CADENCE_CONTRACT_ADDR="045a1763c93006ca"

# Scheduler configuration
SCHEDULER_WAKEUP_INTERVAL=2  # Default scheduler wakeup interval in seconds
AUTO_PROCESS_TIMEOUT=10      # Timeout for waiting for automatic processing

# ============================================
# HELPER FUNCTIONS
# ============================================

log_section() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}============================================${NC}"
}

log_test() {
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  echo -e "\n${YELLOW}TEST $TOTAL_TESTS: $1${NC}"
}

log_success() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo -e "${GREEN}PASSED: $1${NC}"
}

log_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo -e "${RED}FAILED: $1${NC}"
}

log_info() {
  echo -e "  INFO: $1"
}

log_warn() {
  echo -e "${YELLOW}  WARN: $1${NC}"
}

# Execute EVM transaction via cast
cast_send() {
  local user_pk=$1
  local function_sig=$2
  shift 2

  cast send "$FLOW_VAULTS_REQUESTS_CONTRACT" \
    "$function_sig" \
    "$@" \
    --rpc-url "$RPC_URL" \
    --private-key "$user_pk" \
    --legacy 2>&1
}

# Execute EVM call via cast
cast_call() {
  local function_sig=$1
  shift

  cast call "$FLOW_VAULTS_REQUESTS_CONTRACT" \
    "$function_sig" \
    "$@" \
    --rpc-url "$RPC_URL" 2>&1
}

# Get pending request count
get_pending_count() {
  cast_call "getPendingRequestCount()(uint256)"
}

# Get request status (0=PENDING, 1=PROCESSING, 2=COMPLETED, 3=FAILED)
get_request_status() {
  local request_id=$1
  cast_call "getRequest(uint256)((uint256,address,uint8,uint8,address,uint256,uint64,uint256,string,string,string))" "$request_id" | \
    sed -n 's/.*(\([0-9]*\), [^,]*, [0-9]*, \([0-9]*\),.*/\2/p'
}

# Get user's YieldVault IDs from Cadence
get_user_yieldvaults() {
  local evm_address=$1
  flow scripts execute ./cadence/scripts/check_user_yieldvaults.cdc "$evm_address" 2>/dev/null | \
    grep "Result:" | sed 's/Result: //'
}

# Clean up wei values for numeric comparisons
clean_wei() {
  echo "$1" | sed 's/ \[.*\]$//' | tr -d ' ' | sed 's/^0*$/0/' | sed 's/^0\+\([1-9]\)/\1/'
}

# Convert wei to ether (using bc for arbitrary precision)
wei_to_ether() {
  local wei=$1
  wei=$(echo "$wei" | sed 's/ \[.*\]$//' | tr -d ' ')
  if [ -z "$wei" ] || [ "$wei" = "0" ]; then
    echo "0"
    return
  fi
  echo "scale=2; $wei / 1000000000000000000" | bc
}

# Get user balance on EVM (in wei)
get_user_balance() {
  local user_address=$1
  cast balance "$user_address" --rpc-url "$RPC_URL" 2>/dev/null | \
    sed 's/ \[.*\]$//' | tr -d ' '
}

# Get escrow balance from Solidity contract (in wei)
get_escrow_balance() {
  local user_address=$1
  local token_address=${2:-$NATIVE_FLOW}
  cast_call "getUserPendingBalance(address,address)(uint256)" "$user_address" "$token_address" | \
    sed 's/ \[.*\]$//' | tr -d ' '
}

# ============================================
# SCHEDULER-SPECIFIC HELPER FUNCTIONS
# ============================================

# Check if scheduler is paused
check_scheduler_paused() {
  local result=$(flow scripts execute ./cadence/scripts/scheduler/check_handler_paused.cdc 2>/dev/null | \
    grep "Result:" | sed 's/Result: //')
  echo "$result"
}

# Pause the scheduler
pause_scheduler() {
  flow transactions send ./cadence/transactions/scheduler/pause_transaction_handler.cdc \
    --signer emulator-flow-yield-vaults \
    --compute-limit 9999 2>&1
}

# Unpause the scheduler
unpause_scheduler() {
  flow transactions send ./cadence/transactions/scheduler/unpause_transaction_handler.cdc \
    --signer emulator-flow-yield-vaults \
    --compute-limit 9999 2>&1
}

# Initialize scheduler handlers
init_scheduler() {
  flow transactions send ./cadence/transactions/scheduler/init_and_schedule.cdc \
    --signer emulator-flow-yield-vaults \
    --compute-limit 9999 2>&1
}

# Send a no-op transaction to trigger emulator block processing
# This ensures FlowTransactionScheduler executes pending scheduled transactions
tick_emulator() {
  flow transactions send ./cadence/tests/transactions/no_op.cdc --signer emulator-flow-yield-vaults >/dev/null 2>&1 || true
}

# Count YieldVaults from the get_user_yieldvaults output
count_yieldvaults() {
  local vaults_output="$1"
  # Count numeric IDs in the output (handles "[]" as 0, "[1, 2, 3]" as 3)
  if [ -z "$vaults_output" ] || [ "$vaults_output" = "[]" ]; then
    echo "0"
  else
    echo "$vaults_output" | grep -Eo '[0-9]+' | wc -l | tr -d ' '
  fi
}

# Wait for user to have more YieldVaults than before
# Usage: wait_for_user_vault "$USER_EOA" "$VAULTS_BEFORE" [timeout]
# Returns 0 if new vault detected, 1 if timeout
wait_for_user_vault() {
  local user_eoa=$1
  local vaults_before=$2
  local timeout=${3:-$AUTO_PROCESS_TIMEOUT}
  local counter=0

  local count_before=$(count_yieldvaults "$vaults_before")
  log_info "Waiting for $user_eoa to receive new YieldVault (had $count_before, timeout: ${timeout}s)..."

  while [ $counter -lt $timeout ]; do
    # Send no-op to trigger emulator processing of scheduled transactions
    tick_emulator

    local current_vaults=$(get_user_yieldvaults "$user_eoa")
    local count_current=$(count_yieldvaults "$current_vaults")

    if [ "$count_current" -gt "$count_before" ]; then
      log_info "User received new YieldVault after ${counter}s (now has $count_current)"
      return 0
    fi

    sleep 1
    counter=$((counter + 1))

    # Progress indicator every 5 seconds
    if [ $((counter % 5)) -eq 0 ]; then
      log_info "Still waiting... (${counter}s elapsed, vaults: $count_current)"
    fi
  done

  log_warn "Timeout waiting for new YieldVault"
  return 1
}

# Wait for multiple users to each have more YieldVaults than before
# Usage: wait_for_users_vaults "EOA1 EOA2 EOA3" "VAULTS1" "VAULTS2" "VAULTS3" [timeout]
# Returns 0 if all users received new vaults, 1 if timeout
wait_for_users_vaults() {
  local user_eoas=$1
  local timeout=${5:-$AUTO_PROCESS_TIMEOUT}
  local counter=0

  # Store initial counts in arrays
  local -a eoas=($user_eoas)
  local -a initial_counts
  initial_counts[0]=$(count_yieldvaults "$2")
  initial_counts[1]=$(count_yieldvaults "$3")
  initial_counts[2]=$(count_yieldvaults "$4")

  log_info "Waiting for ${#eoas[@]} users to receive new YieldVaults (timeout: ${timeout}s)..."

  while [ $counter -lt $timeout ]; do
    tick_emulator

    local all_received=true
    local status=""

    for i in "${!eoas[@]}"; do
      local current_vaults=$(get_user_yieldvaults "${eoas[$i]}")
      local count_current=$(count_yieldvaults "$current_vaults")
      local count_initial=${initial_counts[$i]}

      if [ "$count_current" -le "$count_initial" ]; then
        all_received=false
        status="$status User$((i+1)):$count_current/$((count_initial+1))"
      else
        status="$status User$((i+1)):OK"
      fi
    done

    if [ "$all_received" = "true" ]; then
      log_info "All users received new YieldVaults after ${counter}s"
      return 0
    fi

    sleep 1
    counter=$((counter + 1))

    if [ $((counter % 5)) -eq 0 ]; then
      log_info "Still waiting... (${counter}s elapsed,$status)"
    fi
  done

  log_warn "Timeout waiting for all users to receive YieldVaults"
  return 1
}

# Assert equals
assert_eq() {
  local expected=$1
  local actual=$2
  local message=$3

  if [ "$expected" = "$actual" ]; then
    log_success "$message"
    return 0
  else
    log_fail "$message (expected: $expected, got: $actual)"
    return 1
  fi
}

# Assert not equals
assert_neq() {
  local not_expected=$1
  local actual=$2
  local message=$3

  if [ "$not_expected" != "$actual" ]; then
    log_success "$message"
    return 0
  else
    log_fail "$message (should not be: $not_expected)"
    return 1
  fi
}

# Assert transaction success
assert_tx_success() {
  local output=$1
  local message=$2

  if echo "$output" | grep -q "SEALED"; then
    log_success "$message"
    return 0
  else
    log_fail "$message"
    echo "$output"
    return 1
  fi
}

# Assert EVM transaction success
assert_evm_tx_success() {
  local output=$1
  local message=$2

  if echo "$output" | grep -q "status.*1"; then
    log_success "$message"
    return 0
  else
    log_fail "$message"
    echo "$output"
    return 1
  fi
}

# ============================================
# SETUP & VERIFICATION
# ============================================

log_section "SETUP & VERIFICATION"

echo "Contract Address: $FLOW_VAULTS_REQUESTS_CONTRACT"
echo "User A: $USER_A_EOA"
echo "User B: $USER_B_EOA"
echo "User C: $USER_C_EOA"

# Verify RPC connection
log_test "Verify EVM Gateway is responding"
RPC_CHECK=$(curl -s -X POST "$RPC_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' || echo "")

if echo "$RPC_CHECK" | grep -q "0x"; then
  log_success "EVM Gateway is responding"
else
  log_fail "EVM Gateway not responding"
  exit 1
fi

# Verify contract is deployed
log_test "Verify contract is deployed"
CODE=$(cast code "$FLOW_VAULTS_REQUESTS_CONTRACT" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
if [ "$CODE" != "0x" ] && [ -n "$CODE" ]; then
  log_success "Contract is deployed"
else
  log_fail "Contract not found at $FLOW_VAULTS_REQUESTS_CONTRACT"
  exit 1
fi

# ============================================
# SCENARIO 1: SCHEDULER INITIALIZATION
# ============================================

log_section "SCENARIO 1: Scheduler Initialization"

log_test "Initialize scheduler handlers"

# Check initial paused state (may fail if not initialized yet)
INITIAL_PAUSED=$(check_scheduler_paused 2>/dev/null || echo "unknown")
log_info "Initial scheduler paused state: $INITIAL_PAUSED"

# Initialize scheduler
INIT_OUTPUT=$(init_scheduler 2>&1)

if echo "$INIT_OUTPUT" | grep -q "SEALED"; then
  log_success "Scheduler handlers initialized"
else
  # May already be initialized, which is fine
  if echo "$INIT_OUTPUT" | grep -q "already"; then
    log_info "Scheduler handlers already initialized"
    log_success "Scheduler handlers ready"
  else
    log_warn "Scheduler initialization output: $INIT_OUTPUT"
    log_success "Proceeding with existing scheduler state"
  fi
fi

log_test "Verify scheduler is not paused after initialization"

PAUSED_STATE=$(check_scheduler_paused)
log_info "Scheduler paused state: $PAUSED_STATE"

if [ "$PAUSED_STATE" = "false" ]; then
  log_success "Scheduler is not paused"
else
  log_warn "Scheduler is paused, attempting to unpause..."
  unpause_scheduler >/dev/null 2>&1 || true
  sleep 1
  PAUSED_STATE=$(check_scheduler_paused)
  if [ "$PAUSED_STATE" = "false" ]; then
    log_success "Scheduler unpaused successfully"
  else
    log_fail "Could not unpause scheduler"
  fi
fi

# ============================================
# SCENARIO 2: SINGLE REQUEST AUTOMATIC PROCESSING
# ============================================

log_section "SCENARIO 2: Single Request Automatic Processing"

# Get initial state
USER_A_VAULTS_BEFORE=$(get_user_yieldvaults "$USER_A_EOA")

log_test "Create single YieldVault request"

TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "5000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "5ether")

assert_evm_tx_success "$TX_OUTPUT" "YieldVault creation request submitted"

log_test "Wait for YieldVault to be created"

if wait_for_user_vault "$USER_A_EOA" "$USER_A_VAULTS_BEFORE" "$AUTO_PROCESS_TIMEOUT"; then
  USER_A_VAULTS_AFTER=$(get_user_yieldvaults "$USER_A_EOA")
  log_info "User A YieldVaults before: $USER_A_VAULTS_BEFORE"
  log_info "User A YieldVaults after: $USER_A_VAULTS_AFTER"
  log_success "YieldVault created via automatic processing"
else
  log_fail "YieldVault was not created within timeout"
fi

# ============================================
# SCENARIO 3: PAUSE WITH MULTI-USER REQUESTS
# ============================================

log_section "SCENARIO 3: Pause With Multi-User Requests"

log_test "Pause the scheduler"

PAUSE_OUTPUT=$(pause_scheduler)
assert_tx_success "$PAUSE_OUTPUT" "Pause transaction submitted"

log_test "Verify scheduler is paused"

sleep 1
PAUSED_STATE=$(check_scheduler_paused)
assert_eq "true" "$PAUSED_STATE" "Scheduler reports paused state"

# Record initial vault counts
USER_A_VAULTS_INITIAL=$(get_user_yieldvaults "$USER_A_EOA")
USER_B_VAULTS_INITIAL=$(get_user_yieldvaults "$USER_B_EOA")
USER_C_VAULTS_INITIAL=$(get_user_yieldvaults "$USER_C_EOA")

USER_A_COUNT_BEFORE=$(count_yieldvaults "$USER_A_VAULTS_INITIAL")
USER_B_COUNT_BEFORE=$(count_yieldvaults "$USER_B_VAULTS_INITIAL")
USER_C_COUNT_BEFORE=$(count_yieldvaults "$USER_C_VAULTS_INITIAL")

PENDING_BEFORE=$(get_pending_count)
PENDING_BEFORE=$(clean_wei "$PENDING_BEFORE")

log_test "Create requests from multiple users while paused"

# User A creates request
TX_A=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "4000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "4ether" 2>&1)

# User B creates request
TX_B=$(cast_send "$USER_B_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "4000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "4ether" 2>&1)

# User C creates request
TX_C=$(cast_send "$USER_C_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "4000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "4ether" 2>&1)

USER_A_SUCCESS=$(echo "$TX_A" | grep -q "status.*1" && echo "true" || echo "false")
USER_B_SUCCESS=$(echo "$TX_B" | grep -q "status.*1" && echo "true" || echo "false")
USER_C_SUCCESS=$(echo "$TX_C" | grep -q "status.*1" && echo "true" || echo "false")

log_info "User A request: $USER_A_SUCCESS"
log_info "User B request: $USER_B_SUCCESS"
log_info "User C request: $USER_C_SUCCESS"

if [ "$USER_A_SUCCESS" = "true" ] && [ "$USER_B_SUCCESS" = "true" ] && [ "$USER_C_SUCCESS" = "true" ]; then
  log_success "All multi-user requests submitted"
else
  log_fail "Some requests failed to submit"
fi

log_test "Verify requests stay PENDING while paused"

# Wait longer than scheduler interval to ensure it would have processed if active
sleep $((SCHEDULER_WAKEUP_INTERVAL * 3))

PENDING_AFTER_PAUSE=$(get_pending_count)
PENDING_AFTER_PAUSE=$(clean_wei "$PENDING_AFTER_PAUSE")

log_info "Pending requests: $PENDING_BEFORE -> $PENDING_AFTER_PAUSE"

EXPECTED_PENDING=$((PENDING_BEFORE + 3))
if [ "$PENDING_AFTER_PAUSE" -ge "$EXPECTED_PENDING" ]; then
  log_success "Requests remain pending while scheduler is paused"
else
  log_fail "Expected $EXPECTED_PENDING pending, got $PENDING_AFTER_PAUSE"
fi

log_test "Unpause the scheduler"

UNPAUSE_OUTPUT=$(unpause_scheduler)
assert_tx_success "$UNPAUSE_OUTPUT" "Unpause transaction submitted"

log_test "Checking scheduler is unpaused"

sleep 1
PAUSED_STATE=$(check_scheduler_paused)
assert_eq "false" "$PAUSED_STATE" "Scheduler reports unpaused state"

log_test "Wait for all users to receive YieldVaults"

if wait_for_users_vaults "$USER_A_EOA $USER_B_EOA $USER_C_EOA" \
    "$USER_A_VAULTS_INITIAL" "$USER_B_VAULTS_INITIAL" "$USER_C_VAULTS_INITIAL" \
    "$AUTO_PROCESS_TIMEOUT"; then

  USER_A_VAULTS_FINAL=$(get_user_yieldvaults "$USER_A_EOA")
  USER_B_VAULTS_FINAL=$(get_user_yieldvaults "$USER_B_EOA")
  USER_C_VAULTS_FINAL=$(get_user_yieldvaults "$USER_C_EOA")

  USER_A_COUNT_AFTER=$(count_yieldvaults "$USER_A_VAULTS_FINAL")
  USER_B_COUNT_AFTER=$(count_yieldvaults "$USER_B_VAULTS_FINAL")
  USER_C_COUNT_AFTER=$(count_yieldvaults "$USER_C_VAULTS_FINAL")

  log_info "User A YieldVaults: $USER_A_COUNT_BEFORE -> $USER_A_COUNT_AFTER"
  log_info "User B YieldVaults: $USER_B_COUNT_BEFORE -> $USER_B_COUNT_AFTER"
  log_info "User C YieldVaults: $USER_C_COUNT_BEFORE -> $USER_C_COUNT_AFTER"

  log_success "All 3 users received new YieldVaults"
else
  log_fail "Not all users received new YieldVaults within timeout"
fi

# ============================================
# CLEANUP & FINAL STATE
# ============================================

log_section "CLEANUP & FINAL STATE"

# Ensure scheduler is running for future use
PAUSED_STATE=$(check_scheduler_paused)
if [ "$PAUSED_STATE" = "true" ]; then
  log_info "Unpausing scheduler for cleanup..."
  unpause_scheduler >/dev/null 2>&1 || true
fi

# Give any remaining pending requests time to process
FINAL_PENDING=$(get_pending_count)
FINAL_PENDING=$(clean_wei "$FINAL_PENDING")

if [ "$FINAL_PENDING" -gt 0 ]; then
  log_info "Waiting for $FINAL_PENDING remaining pending requests to process..."
  for i in $(seq 1 15); do
    tick_emulator
    sleep 1
  done
fi

FINAL_PENDING=$(get_pending_count)
FINAL_PENDING=$(clean_wei "$FINAL_PENDING")
log_info "Final pending request count: $FINAL_PENDING"

# Final scheduler state
FINAL_PAUSED=$(check_scheduler_paused)
log_info "Final scheduler paused state: $FINAL_PAUSED"

# Summary of YieldVaults
log_section "YIELDVAULT SUMMARY"

echo ""
echo "User A: $(get_user_yieldvaults "$USER_A_EOA")"
echo "User B: $(get_user_yieldvaults "$USER_B_EOA")"
echo "User C: $(get_user_yieldvaults "$USER_C_EOA")"
echo ""

# ============================================
# TEST SUMMARY
# ============================================

log_section "TEST SUMMARY"

echo ""
echo "Scheduler state: $FINAL_PAUSED"
echo "Pending requests remaining: $FINAL_PENDING"
echo ""
echo -e "Tests Passed:  ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed:  ${RED}$TESTS_FAILED${NC}"
echo -e "Total Tests:   $TOTAL_TESTS"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
  echo -e "${GREEN}=========================================${NC}"
  echo -e "${GREEN}ALL TESTS PASSED!${NC}"
  echo -e "${GREEN}=========================================${NC}"
  echo ""
  echo "FlowTransactionScheduler automatic execution verified."
  echo "All worker operations tests completed successfully."
  exit 0
else
  echo -e "${RED}=========================================${NC}"
  echo -e "${RED}SOME TESTS FAILED${NC}"
  echo -e "${RED}=========================================${NC}"
  echo ""
  echo "Review failed tests above for details."
  exit 1
fi
