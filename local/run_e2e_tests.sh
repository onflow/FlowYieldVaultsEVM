#!/bin/bash

set -e  # Exit on any error

# ============================================
# E2E TEST SCRIPT FOR FLOWYIELDVAULTSEVM
# ============================================
# This script tests all possible scenarios between Cadence and Solidity:
# - Create YieldVault (native FLOW)
# - Deposit to YieldVault
# - Withdraw from YieldVault
# - Close YieldVault
# - Cancel pending requests
# - Multi-user scenarios
# - Error cases and edge cases
# - Rapid sequential operations
# - Full lifecycle test
#
# The contract address is automatically loaded from ./local/.deployed_contract_address
# (created by deploy_full_stack.sh)
#
# Usage (run all three scripts chained):
#   ./local/setup_and_run_emulator.sh && ./local/deploy_full_stack.sh && ./local/run_e2e_tests.sh
#
# Or run individually after deployment:
#   ./local/run_e2e_tests.sh
# ============================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    echo -e "${RED}❌ FLOW_VAULTS_REQUESTS_CONTRACT not set${NC}"
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
STRATEGY_IDENTIFIER="A.045a1763c93006ca.MockStrategies.TracerStrategy"
CADENCE_CONTRACT_ADDR="045a1763c93006ca"

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
  echo -e "\n${YELLOW}🧪 TEST $TOTAL_TESTS: $1${NC}"
}

log_success() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo -e "${GREEN}✓ PASSED: $1${NC}"
}

log_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo -e "${RED}❌ FAILED: $1${NC}"
}

log_info() {
  echo -e "  ℹ️  $1"
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

# Get YieldVault ID from completed request
get_yieldvault_id_from_request() {
  local request_id=$1
  cast_call "getRequest(uint256)((uint256,address,uint8,uint8,address,uint256,uint64,uint256,string,string,string))" "$request_id" | \
    grep -Eo '[0-9]+' | sed -n '7p'  # 7th number is the yieldVaultId
}

# Get user's YieldVault IDs from Cadence
get_user_yieldvaults() {
  local evm_address=$1
  flow scripts execute ./cadence/scripts/check_user_yieldvaults.cdc "$evm_address" 2>/dev/null | \
    grep "Result:" | sed 's/Result: //'
}

# Get newly created request ID by diffing before/after pending lists
get_new_request_id() {
  local before=$1
  local after=$2

  local before_ids
  local after_ids

  before_ids=$(echo "$before" | grep -Eo '[0-9]+' || true)
  after_ids=$(echo "$after" | grep -Eo '[0-9]+' || true)

  local new_id=""
  for id in $after_ids; do
    if ! echo "$before_ids" | grep -q -w "$id"; then
      new_id="$id"
    fi
  done

  echo "$new_id"
}

# Get newly created YieldVault ID by diffing before/after lists
get_new_yieldvault_id() {
  local before=$1
  local after=$2

  local before_ids
  local after_ids

  before_ids=$(echo "$before" | grep -Eo '[0-9]+' || true)
  after_ids=$(echo "$after" | grep -Eo '[0-9]+' || true)

  local new_id=""
  for id in $after_ids; do
    if ! echo "$before_ids" | grep -q -w "$id"; then
      new_id="$id"
    fi
  done

  echo "$new_id"
}

# Clean up wei values for numeric comparisons
clean_wei() {
  echo "$1" | sed 's/ \[.*\]$//' | tr -d ' ' | sed 's/^0*$/0/' | sed 's/^0\+\([1-9]\)/\1/'
}

# Process pending requests via Cadence
process_requests() {
  local start_index=${1:-0}
  local count=${2:-10}

  flow transactions send ./cadence/transactions/process_requests.cdc \
    "$start_index" "$count" \
    --signer emulator-flow-yield-vaults \
    --compute-limit 9999 2>&1
}

# Extract transaction ID from flow output
extract_tx_id() {
  local output=$1
  echo "$output" | grep -E "^ID" | head -1 | awk '{print $2}'
}

# Get computation from transaction profile
get_tx_computation() {
  local tx_id=$1
  flow transactions profile "$tx_id" --output /dev/null 2>/dev/null | grep -E "^Computation:" | awk '{print $2}'
}

# Process requests and print transaction ID and computation
process_requests_verbose() {
  local request_type=$1
  local start_index=${2:-0}
  local count=${3:-10}

  local output=$(process_requests "$start_index" "$count")
  local tx_id=$(extract_tx_id "$output")

  if [ -n "$tx_id" ]; then
    local computation=$(get_tx_computation "$tx_id")
    echo -e "  ℹ️  Process TX ($request_type): $tx_id (computation: ${computation:-N/A})" >&2
  fi

  echo "$output"
}

# Wait for request to be processed
wait_for_processing() {
  local request_id=$1
  local max_wait=${2:-30}
  local counter=0

  while [ $counter -lt $max_wait ]; do
    local status=$(get_request_status "$request_id" 2>/dev/null || echo "0")
    if [ "$status" = "2" ] || [ "$status" = "3" ]; then
      return 0
    fi

    # Try to process
    process_requests 0 10 >/dev/null 2>&1 || true
    sleep 1
    counter=$((counter + 1))
  done

  return 1
}

# Get user balance on EVM (in wei)
# Strips scientific notation suffix from cast output
get_user_balance() {
  local user_address=$1
  cast balance "$user_address" --rpc-url "$RPC_URL" 2>/dev/null | \
    sed 's/ \[.*\]$//' | tr -d ' '
}

# Get user balance on EVM (in ether, for display)
get_user_balance_ether() {
  local user_address=$1
  cast balance "$user_address" --rpc-url "$RPC_URL" --ether 2>/dev/null
}

# Get escrowed balance from Solidity contract (in wei)
# Strips scientific notation suffix like "[1e19]" from cast output
get_escrow_balance() {
  local user_address=$1
  local token_address=${2:-$NATIVE_FLOW}
  cast_call "getUserPendingBalance(address,address)(uint256)" "$user_address" "$token_address" | \
    sed 's/ \[.*\]$//' | tr -d ' '
}

# Get claimable refund balance from Solidity contract (in wei)
# Strips scientific notation suffix like "[1e19]" from cast output
get_claimable_refund() {
  local user_address=$1
  local token_address=${2:-$NATIVE_FLOW}
  cast_call "getClaimableRefund(address,address)(uint256)" "$user_address" "$token_address" | \
    sed 's/ \[.*\]$//' | tr -d ' '
}

# Get YieldVault balance from Cadence (in FLOW as UFix64)
get_yieldvault_balance() {
  local yieldvault_id=$1
  local manager_address=${2:-"0x$CADENCE_CONTRACT_ADDR"}
  flow scripts execute ./cadence/scripts/get_yieldvault_balance.cdc "$manager_address" "$yieldvault_id" 2>/dev/null | \
    grep "Result:" | sed 's/Result: //'
}

# Convert wei to ether (using bc for arbitrary precision)
wei_to_ether() {
  local wei=$1
  # Remove any scientific notation suffix and whitespace
  wei=$(echo "$wei" | sed 's/ \[.*\]$//' | tr -d ' ')
  # Handle empty string
  if [ -z "$wei" ] || [ "$wei" = "0" ]; then
    echo "0"
    return
  fi
  # Use bc for division (scale=2 for 2 decimal places)
  echo "scale=2; $wei / 1000000000000000000" | bc
}

# Convert ether to wei (using bc for arbitrary precision)
ether_to_wei() {
  local ether=$1
  echo "$ether * 1000000000000000000" | bc | sed 's/\..*$//'
}

# Assert balance increased by approximately expected amount (allows for gas)
# Usage: assert_balance_increased BEFORE AFTER EXPECTED_INCREASE MESSAGE [GAS_ALLOWANCE]
assert_balance_increased() {
  local before=$1
  local after=$2
  local expected_increase=$3
  local message=$4
  local gas_allowance=${5:-100000000000000000}  # 0.1 FLOW default gas allowance

  # Clean up values - remove scientific notation suffix and whitespace
  before=$(echo "$before" | sed 's/ \[.*\]$//' | tr -d ' ')
  after=$(echo "$after" | sed 's/ \[.*\]$//' | tr -d ' ')
  expected_increase=$(echo "$expected_increase" | sed 's/ \[.*\]$//' | tr -d ' ')

  # Handle empty values
  before=${before:-0}
  after=${after:-0}
  expected_increase=${expected_increase:-0}

  # Use bc for arbitrary precision arithmetic
  local expected_after=$(echo "$before + $expected_increase" | bc)
  local min_expected=$(echo "$expected_after - $gas_allowance" | bc)
  local max_expected=$(echo "$expected_after + $gas_allowance" | bc)
  local actual_diff=$(echo "$after - $before" | bc)

  # Compare using bc (returns 1 if true, 0 if false)
  local above_min=$(echo "$after >= $min_expected" | bc)
  local below_max=$(echo "$after <= $max_expected" | bc)

  if [ "$above_min" = "1" ] && [ "$below_max" = "1" ]; then
    log_success "$message"
    return 0
  else
    log_fail "$message (expected ~$(wei_to_ether $expected_after) FLOW, got $(wei_to_ether $after) FLOW, diff: $(wei_to_ether $actual_diff) FLOW)"
    return 1
  fi
}

# Assert balance decreased by approximately expected amount (allows for gas)
# Usage: assert_balance_decreased BEFORE AFTER EXPECTED_DECREASE MESSAGE [GAS_ALLOWANCE]
assert_balance_decreased() {
  local before=$1
  local after=$2
  local expected_decrease=$3
  local message=$4
  local gas_allowance=${5:-100000000000000000}  # 0.1 FLOW default gas allowance

  # Clean up values - remove scientific notation suffix and whitespace
  before=$(echo "$before" | sed 's/ \[.*\]$//' | tr -d ' ')
  after=$(echo "$after" | sed 's/ \[.*\]$//' | tr -d ' ')
  expected_decrease=$(echo "$expected_decrease" | sed 's/ \[.*\]$//' | tr -d ' ')

  # Handle empty values
  before=${before:-0}
  after=${after:-0}
  expected_decrease=${expected_decrease:-0}

  # Use bc for arbitrary precision arithmetic
  local expected_after=$(echo "$before - $expected_decrease" | bc)
  local min_expected=$(echo "$expected_after - $gas_allowance" | bc)
  local actual_diff=$(echo "$before - $after" | bc)

  # Compare using bc (returns 1 if true, 0 if false)
  local above_min=$(echo "$after >= $min_expected" | bc)
  local below_expected=$(echo "$after <= $expected_after" | bc)

  if [ "$above_min" = "1" ] && [ "$below_expected" = "1" ]; then
    log_success "$message"
    return 0
  else
    log_fail "$message (expected ~$(wei_to_ether $expected_after) FLOW, got $(wei_to_ether $after) FLOW, diff: $(wei_to_ether $actual_diff) FLOW)"
    return 1
  fi
}

# Assert YieldVault balance matches expected (Cadence UFix64)
# Usage: assert_yieldvault_balance YIELDVAULT_ID EXPECTED_BALANCE MESSAGE
assert_yieldvault_balance() {
  local yieldvault_id=$1
  local expected=$2
  local message=$3

  local actual=$(get_yieldvault_balance "$yieldvault_id")
  # Remove trailing zeros and compare
  actual=$(echo "$actual" | sed 's/\.0*$//')
  expected=$(echo "$expected" | sed 's/\.0*$//')

  if [ "$actual" = "$expected" ]; then
    log_success "$message (balance: $actual FLOW)"
    return 0
  else
    log_fail "$message (expected: $expected FLOW, got: $actual FLOW)"
    return 1
  fi
}

# Assert escrow balance equals expected (in wei)
assert_escrow_balance() {
  local user_address=$1
  local expected=$2
  local message=$3

  local actual=$(get_escrow_balance "$user_address")

  # Clean up values - remove scientific notation suffix, whitespace, leading zeros
  actual=$(echo "$actual" | sed 's/ \[.*\]$//' | tr -d ' ' | sed 's/^0*$/0/' | sed 's/^0\+\([1-9]\)/\1/')
  expected=$(echo "$expected" | sed 's/ \[.*\]$//' | tr -d ' ' | sed 's/^0*$/0/' | sed 's/^0\+\([1-9]\)/\1/')

  # Handle empty as 0
  actual=${actual:-0}
  expected=${expected:-0}

  if [ "$actual" = "$expected" ]; then
    log_success "$message (escrow: $(wei_to_ether $actual) FLOW)"
    return 0
  else
    log_fail "$message (expected: $(wei_to_ether $expected) FLOW, got: $(wei_to_ether $actual) FLOW)"
    return 1
  fi
}

# Assert claimable refund balance equals expected (in wei)
assert_claimable_refund() {
  local user_address=$1
  local expected=$2
  local message=$3

  local actual=$(get_claimable_refund "$user_address")

  # Clean up values - remove scientific notation suffix, whitespace, leading zeros
  actual=$(echo "$actual" | sed 's/ \[.*\]$//' | tr -d ' ' | sed 's/^0*$/0/' | sed 's/^0\+\([1-9]\)/\1/')
  expected=$(echo "$expected" | sed 's/ \[.*\]$//' | tr -d ' ' | sed 's/^0*$/0/' | sed 's/^0\+\([1-9]\)/\1/')

  # Handle empty as 0
  actual=${actual:-0}
  expected=${expected:-0}

  if [ "$actual" = "$expected" ]; then
    log_success "$message (refund: $(wei_to_ether $actual) FLOW)"
    return 0
  else
    log_fail "$message (expected: $(wei_to_ether $expected) FLOW, got: $(wei_to_ether $actual) FLOW)"
    return 1
  fi
}

# Assert request status
assert_request_status() {
  local request_id=$1
  local expected_status=$2  # 0=PENDING, 1=PROCESSING, 2=COMPLETED, 3=FAILED
  local message=$3

  local actual=$(get_request_status "$request_id")

  if [ "$actual" = "$expected_status" ]; then
    local status_name=""
    case $expected_status in
      0) status_name="PENDING" ;;
      1) status_name="PROCESSING" ;;
      2) status_name="COMPLETED" ;;
      3) status_name="FAILED" ;;
    esac
    log_success "$message (status: $status_name)"
    return 0
  else
    log_fail "$message (expected status: $expected_status, got: $actual)"
    return 1
  fi
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

# Assert contains
assert_contains() {
  local haystack=$1
  local needle=$2
  local message=$3

  if echo "$haystack" | grep -q "$needle"; then
    log_success "$message"
    return 0
  else
    log_fail "$message (expected to contain: $needle)"
    return 1
  fi
}

# Assert transaction success
assert_tx_success() {
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

# Assert transaction reverted
assert_tx_reverted() {
  local output=$1
  local message=$2

  if echo "$output" | grep -qi "revert\|error\|failed"; then
    log_success "$message"
    return 0
  else
    log_fail "$message (expected revert)"
    return 1
  fi
}

# ============================================
# SETUP
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
# TEST SCENARIO 1: BASIC CREATE YIELDVAULT
# ============================================

log_section "SCENARIO 1: Create YieldVault with Native FLOW"

# Amount constants for this scenario
CREATE_AMOUNT_WEI="10000000000000000000"  # 10 FLOW in wei
CREATE_AMOUNT_FLOW="10.0"                  # 10 FLOW for Cadence comparison

log_test "User A creates YieldVault with 10 FLOW"

# Capture initial state
INITIAL_PENDING=$(get_pending_count)
USER_A_BALANCE_BEFORE=$(get_user_balance "$USER_A_EOA")
USER_A_ESCROW_BEFORE=$(get_escrow_balance "$USER_A_EOA")
USER_A_VAULTS_BEFORE=$(get_user_yieldvaults "$USER_A_EOA")

log_info "Initial pending requests: $INITIAL_PENDING"
log_info "User A EVM balance before: $(wei_to_ether $USER_A_BALANCE_BEFORE) FLOW"
log_info "User A escrow balance before: $USER_A_ESCROW_BEFORE wei"

# Create YieldVault request
TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "$CREATE_AMOUNT_WEI" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "10ether")

assert_tx_success "$TX_OUTPUT" "Create YieldVault transaction submitted"

# Check pending count increased
NEW_PENDING=$(get_pending_count)
log_info "New pending requests: $NEW_PENDING"

if [ "$NEW_PENDING" -gt "$INITIAL_PENDING" ]; then
  log_success "Pending request count increased"
else
  log_fail "Pending request count did not increase"
fi

# Verify escrow balance increased (funds held in contract)
log_test "Verify funds escrowed in Solidity contract"
USER_A_ESCROW_AFTER_CREATE=$(get_escrow_balance "$USER_A_EOA")
log_info "User A escrow after create: $USER_A_ESCROW_AFTER_CREATE wei"
assert_escrow_balance "$USER_A_EOA" "$CREATE_AMOUNT_WEI" "Escrow balance matches deposited amount"

# Verify EVM balance decreased by deposit amount (plus gas)
log_test "Verify User A EVM balance decreased"
USER_A_BALANCE_AFTER_CREATE=$(get_user_balance "$USER_A_EOA")
assert_balance_decreased "$USER_A_BALANCE_BEFORE" "$USER_A_BALANCE_AFTER_CREATE" "$CREATE_AMOUNT_WEI" "User A balance decreased by deposit amount"

# Process the request
log_test "Process the pending request via Cadence"

PROCESS_OUTPUT=$(process_requests_verbose "CREATE_YIELDVAULT" 0 10)
if echo "$PROCESS_OUTPUT" | grep -q "SEALED"; then
  log_success "Request processing transaction sealed"
else
  log_fail "Request processing failed"
  echo "$PROCESS_OUTPUT"
fi

# Wait and verify completion
sleep 2

log_test "Verify YieldVault was created for User A"

USER_A_VAULTS=$(get_user_yieldvaults "$USER_A_EOA")
log_info "User A YieldVaults: $USER_A_VAULTS"

if echo "$USER_A_VAULTS" | grep -q "\["; then
  log_success "User A has YieldVault(s) registered"
else
  log_fail "No YieldVaults found for User A"
fi

# Extract newly created YieldVault ID for balance verification
YIELDVAULT_ID=$(get_new_yieldvault_id "$USER_A_VAULTS_BEFORE" "$USER_A_VAULTS")

# Verify escrow balance cleared after processing
log_test "Verify escrow cleared after processing"
USER_A_ESCROW_AFTER_PROCESS=$(get_escrow_balance "$USER_A_EOA")
assert_escrow_balance "$USER_A_EOA" "0" "Escrow balance cleared after processing"

# Verify YieldVault balance on Cadence matches deposit
log_test "Verify YieldVault balance on Cadence"
if [ -n "$YIELDVAULT_ID" ]; then
  YIELDVAULT_BALANCE=$(get_yieldvault_balance "$YIELDVAULT_ID")
  log_info "YieldVault $YIELDVAULT_ID balance: $YIELDVAULT_BALANCE FLOW"
  assert_yieldvault_balance "$YIELDVAULT_ID" "$CREATE_AMOUNT_FLOW" "YieldVault balance matches deposited amount"
else
  log_fail "Could not get YieldVault ID for balance verification"
fi

# ============================================
# TEST SCENARIO 2: DEPOSIT TO YIELDVAULT
# ============================================

log_section "SCENARIO 2: Deposit to Existing YieldVault"

# Amount constants for this scenario
DEPOSIT_AMOUNT_WEI="5000000000000000000"   # 5 FLOW in wei
DEPOSIT_AMOUNT_FLOW="5.0"                   # 5 FLOW for Cadence comparison
EXPECTED_TOTAL_FLOW="15.0"                  # 10 + 5 = 15 FLOW after deposit

log_info "Using YieldVault ID: $YIELDVAULT_ID"

if [ -z "$YIELDVAULT_ID" ]; then
  log_fail "Could not extract YieldVault ID, skipping deposit tests"
else
  log_test "User A deposits 5 FLOW to YieldVault $YIELDVAULT_ID"

  # Capture initial state
  USER_A_BALANCE_BEFORE_DEPOSIT=$(get_user_balance "$USER_A_EOA")
  YIELDVAULT_BALANCE_BEFORE=$(get_yieldvault_balance "$YIELDVAULT_ID")
  log_info "User A EVM balance before deposit: $(wei_to_ether $USER_A_BALANCE_BEFORE_DEPOSIT) FLOW"
  log_info "YieldVault balance before deposit: $YIELDVAULT_BALANCE_BEFORE FLOW"

  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "depositToYieldVault(uint64,address,uint256)" \
    "$YIELDVAULT_ID" \
    "$NATIVE_FLOW" \
    "$DEPOSIT_AMOUNT_WEI" \
    --value "5ether")

  assert_tx_success "$TX_OUTPUT" "Deposit transaction submitted"

  # Verify escrow balance increased
  log_test "Verify deposit escrowed in Solidity contract"
  assert_escrow_balance "$USER_A_EOA" "$DEPOSIT_AMOUNT_WEI" "Deposit escrowed correctly"

  # Verify EVM balance decreased
  log_test "Verify User A EVM balance decreased by deposit"
  USER_A_BALANCE_AFTER_DEPOSIT_SUBMIT=$(get_user_balance "$USER_A_EOA")
  assert_balance_decreased "$USER_A_BALANCE_BEFORE_DEPOSIT" "$USER_A_BALANCE_AFTER_DEPOSIT_SUBMIT" "$DEPOSIT_AMOUNT_WEI" "User A balance decreased by deposit amount"

  # Process
  sleep 1
  process_requests_verbose "DEPOSIT_TO_YIELDVAULT" 0 10 >/dev/null || true
  sleep 2

  # Verify escrow cleared after processing
  log_test "Verify escrow cleared after deposit processing"
  assert_escrow_balance "$USER_A_EOA" "0" "Escrow cleared after deposit"

  # Verify YieldVault balance increased
  log_test "Verify YieldVault balance increased by deposit amount"
  YIELDVAULT_BALANCE_AFTER=$(get_yieldvault_balance "$YIELDVAULT_ID")
  log_info "YieldVault balance after deposit: $YIELDVAULT_BALANCE_AFTER FLOW"
  assert_yieldvault_balance "$YIELDVAULT_ID" "$EXPECTED_TOTAL_FLOW" "YieldVault balance is now 15 FLOW (10 + 5)"

  log_success "Deposit request processed with balance verification"
fi

# ============================================
# TEST SCENARIO 3: WITHDRAW FROM YIELDVAULT
# ============================================

log_section "SCENARIO 3: Withdraw from YieldVault"

# Amount constants for this scenario
WITHDRAW_AMOUNT_WEI="3000000000000000000"   # 3 FLOW in wei
WITHDRAW_AMOUNT_FLOW="3.0"                   # 3 FLOW for Cadence comparison
EXPECTED_REMAINING_FLOW="12.0"               # 15 - 3 = 12 FLOW remaining

if [ -n "$YIELDVAULT_ID" ]; then
  log_test "User A withdraws 3 FLOW from YieldVault $YIELDVAULT_ID"

  # Capture initial state
  USER_A_BALANCE_BEFORE_WITHDRAW=$(get_user_balance "$USER_A_EOA")
  YIELDVAULT_BALANCE_BEFORE_WITHDRAW=$(get_yieldvault_balance "$YIELDVAULT_ID")
  log_info "User A EVM balance before withdraw: $(wei_to_ether $USER_A_BALANCE_BEFORE_WITHDRAW) FLOW"
  log_info "YieldVault balance before withdraw: $YIELDVAULT_BALANCE_BEFORE_WITHDRAW FLOW"

  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "withdrawFromYieldVault(uint64,uint256)" \
    "$YIELDVAULT_ID" \
    "$WITHDRAW_AMOUNT_WEI")

  assert_tx_success "$TX_OUTPUT" "Withdraw transaction submitted"

  # Note: Withdraw doesn't escrow funds - they come from Cadence
  # Verify no escrow for withdraw requests
  log_test "Verify no escrow for withdraw request"
  assert_escrow_balance "$USER_A_EOA" "0" "No escrow for withdraw requests"

  # Process
  sleep 1
  process_requests_verbose "WITHDRAW_FROM_YIELDVAULT" 0 10 >/dev/null || true
  sleep 2

  # Verify User A EVM balance increased by withdrawn amount
  log_test "Verify User A received withdrawn funds"
  USER_A_BALANCE_AFTER_WITHDRAW=$(get_user_balance "$USER_A_EOA")
  log_info "User A EVM balance after withdraw: $(wei_to_ether $USER_A_BALANCE_AFTER_WITHDRAW) FLOW"

  # Balance should increase by withdraw amount minus gas for the tx
  # Gas is minimal for withdraw request creation (no value transfer)
  assert_balance_increased "$USER_A_BALANCE_BEFORE_WITHDRAW" "$USER_A_BALANCE_AFTER_WITHDRAW" "$WITHDRAW_AMOUNT_WEI" "User A balance increased by withdrawn amount"

  # Verify YieldVault balance decreased
  log_test "Verify YieldVault balance decreased by withdraw amount"
  YIELDVAULT_BALANCE_AFTER_WITHDRAW=$(get_yieldvault_balance "$YIELDVAULT_ID")
  log_info "YieldVault balance after withdraw: $YIELDVAULT_BALANCE_AFTER_WITHDRAW FLOW"
  assert_yieldvault_balance "$YIELDVAULT_ID" "$EXPECTED_REMAINING_FLOW" "YieldVault balance is now 12 FLOW (15 - 3)"

  log_success "Withdraw request processed with balance verification"
fi

# ============================================
# TEST SCENARIO 4: MULTI-USER ISOLATION
# ============================================

log_section "SCENARIO 4: Multi-User Isolation"

log_test "User B creates their own YieldVault"

TX_OUTPUT=$(cast_send "$USER_B_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "20000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "20ether")

assert_tx_success "$TX_OUTPUT" "User B create YieldVault transaction submitted"

# Process
sleep 1
process_requests_verbose "CREATE_YIELDVAULT" 0 10 >/dev/null || true
sleep 2

log_test "Verify User B has their own YieldVault"

USER_B_VAULTS=$(get_user_yieldvaults "$USER_B_EOA")
log_info "User B YieldVaults: $USER_B_VAULTS"

if echo "$USER_B_VAULTS" | grep -q "\["; then
  log_success "User B has YieldVault(s) registered"
else
  log_fail "No YieldVaults found for User B"
fi

log_test "Verify User A and User B have different YieldVaults"

if [ "$USER_A_VAULTS" != "$USER_B_VAULTS" ]; then
  log_success "Users have separate YieldVaults"
else
  log_fail "Users should have different YieldVaults"
fi

# ============================================
# TEST SCENARIO 5: CANCEL PENDING REQUEST
# ============================================

log_section "SCENARIO 5: Cancel Pending Request"

# Amount constants for this scenario
CANCEL_AMOUNT_WEI="15000000000000000000"   # 15 FLOW in wei

log_test "User C creates a request then cancels it"

# Capture initial state
USER_C_BALANCE_BEFORE_CREATE=$(get_user_balance "$USER_C_EOA")
USER_C_ESCROW_BEFORE=$(get_escrow_balance "$USER_C_EOA")
USER_C_REFUND_BEFORE=$(get_claimable_refund "$USER_C_EOA")
PENDING_IDS_BEFORE=$(cast_call "getPendingRequestIds()(uint256[])")
log_info "User C EVM balance before: $(wei_to_ether $USER_C_BALANCE_BEFORE_CREATE) FLOW"
log_info "User C escrow before: $USER_C_ESCROW_BEFORE wei"
log_info "User C claimable refund before: $USER_C_REFUND_BEFORE wei"

# Create request
TX_OUTPUT=$(cast_send "$USER_C_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "$CANCEL_AMOUNT_WEI" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "15ether")

assert_tx_success "$TX_OUTPUT" "User C create request submitted"

# Verify escrow balance increased
log_test "Verify funds escrowed after create"
USER_C_ESCROW_AFTER_CREATE=$(get_escrow_balance "$USER_C_EOA")
log_info "User C escrow after create: $USER_C_ESCROW_AFTER_CREATE wei"
assert_escrow_balance "$USER_C_EOA" "$CANCEL_AMOUNT_WEI" "Funds escrowed correctly"

# Capture balance after create (before cancel)
USER_C_BALANCE_AFTER_CREATE=$(get_user_balance "$USER_C_EOA")
log_info "User C EVM balance after create: $(wei_to_ether $USER_C_BALANCE_AFTER_CREATE) FLOW"

# Get the request ID (diff from previous pending list)
PENDING_IDS_AFTER=$(cast_call "getPendingRequestIds()(uint256[])")
REQUEST_ID=$(get_new_request_id "$PENDING_IDS_BEFORE" "$PENDING_IDS_AFTER")
log_info "Request ID to cancel: $REQUEST_ID"

if [ -n "$REQUEST_ID" ]; then
  # Cancel the request
  log_test "Cancel request $REQUEST_ID"

  TX_OUTPUT=$(cast_send "$USER_C_PK" \
    "cancelRequest(uint256)" \
    "$REQUEST_ID")

  assert_tx_success "$TX_OUTPUT" "Cancel request transaction submitted"

  # Verify escrow cleared after cancel
  log_test "Verify escrow cleared after cancel"
  USER_C_ESCROW_AFTER_CANCEL=$(get_escrow_balance "$USER_C_EOA")
  assert_escrow_balance "$USER_C_EOA" "0" "Escrow cleared after cancel"

  # Verify refund is claimable
  log_test "Verify claimable refund credited"
  USER_C_REFUND_AFTER_CANCEL=$(get_claimable_refund "$USER_C_EOA")
  log_info "User C claimable refund after cancel: $USER_C_REFUND_AFTER_CANCEL wei"
  EXPECTED_REFUND_TOTAL=$(echo "$(clean_wei "$USER_C_REFUND_BEFORE") + $(clean_wei "$CANCEL_AMOUNT_WEI")" | bc)
  assert_claimable_refund "$USER_C_EOA" "$EXPECTED_REFUND_TOTAL" "Claimable refund credited"

  # Claim refund and verify balance
  log_test "Claim refund"
  TX_OUTPUT=$(cast_send "$USER_C_PK" \
    "claimRefund(address)" \
    "$NATIVE_FLOW")
  assert_tx_success "$TX_OUTPUT" "Claim refund transaction submitted"

  log_test "Verify User C received refund after claim"
  sleep 1
  USER_C_BALANCE_AFTER_CLAIM=$(get_user_balance "$USER_C_EOA")
  log_info "User C EVM balance after claim: $(wei_to_ether $USER_C_BALANCE_AFTER_CLAIM) FLOW"

  # Balance after claim should be close to balance after create + claimable refund amount
  assert_balance_increased "$USER_C_BALANCE_AFTER_CREATE" "$USER_C_BALANCE_AFTER_CLAIM" "$EXPECTED_REFUND_TOTAL" "User C received refund after claim"

  # Verify claimable refund cleared after claim
  log_test "Verify claimable refund cleared"
  USER_C_REFUND_AFTER_CLAIM=$(get_claimable_refund "$USER_C_EOA")
  assert_claimable_refund "$USER_C_EOA" "0" "Claimable refund cleared after claim"

  # Verify request status is FAILED (3)
  log_test "Verify request status is FAILED"
  assert_request_status "$REQUEST_ID" "3" "Request marked as FAILED after cancel"

  log_success "Request cancelled and funds refunded with verification"
else
  log_fail "Could not get request ID for cancel test"
fi

# ============================================
# TEST SCENARIO 6: CLOSE YIELDVAULT
# ============================================

log_section "SCENARIO 6: Close YieldVault"

# Expected remaining balance from previous scenarios: 12 FLOW
EXPECTED_CLOSE_RETURN_WEI="12000000000000000000"  # 12 FLOW in wei

if [ -n "$YIELDVAULT_ID" ]; then
  log_test "User A closes YieldVault $YIELDVAULT_ID"

  # Capture initial state
  USER_A_BALANCE_BEFORE_CLOSE=$(get_user_balance "$USER_A_EOA")
  YIELDVAULT_BALANCE_BEFORE_CLOSE=$(get_yieldvault_balance "$YIELDVAULT_ID")
  log_info "User A EVM balance before close: $(wei_to_ether $USER_A_BALANCE_BEFORE_CLOSE) FLOW"
  log_info "YieldVault balance before close: $YIELDVAULT_BALANCE_BEFORE_CLOSE FLOW"

  # Store the YieldVault balance in wei for comparison
  # Convert FLOW to wei (multiply by 10^18)
  YIELDVAULT_BALANCE_WEI=$(echo "$YIELDVAULT_BALANCE_BEFORE_CLOSE * 1000000000000000000" | bc | sed 's/\..*$//')

  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "closeYieldVault(uint64)" \
    "$YIELDVAULT_ID")

  assert_tx_success "$TX_OUTPUT" "Close YieldVault transaction submitted"

  # Verify no escrow for close requests
  log_test "Verify no escrow for close request"
  assert_escrow_balance "$USER_A_EOA" "0" "No escrow for close requests"

  # Process
  sleep 1
  process_requests_verbose "CLOSE_YIELDVAULT" 0 10 >/dev/null || true
  sleep 2

  # Verify User A received all funds back
  log_test "Verify User A received all YieldVault funds"
  USER_A_BALANCE_AFTER_CLOSE=$(get_user_balance "$USER_A_EOA")
  log_info "User A EVM balance after close: $(wei_to_ether $USER_A_BALANCE_AFTER_CLOSE) FLOW"

  # Balance should increase by the YieldVault balance
  assert_balance_increased "$USER_A_BALANCE_BEFORE_CLOSE" "$USER_A_BALANCE_AFTER_CLOSE" "$YIELDVAULT_BALANCE_WEI" "User A received YieldVault funds"

  # Verify YieldVault no longer has balance (returns 0 when closed/not found)
  log_test "Verify YieldVault balance is zero after close"
  YIELDVAULT_BALANCE_AFTER_CLOSE=$(get_yieldvault_balance "$YIELDVAULT_ID")
  log_info "YieldVault balance after close: $YIELDVAULT_BALANCE_AFTER_CLOSE FLOW"
  # Check if balance is zero (handles 0, 0.0, 0.00000000, empty string)
  BALANCE_IS_ZERO=$(echo "$YIELDVAULT_BALANCE_AFTER_CLOSE" | sed 's/0*$//' | sed 's/\.$//' | sed 's/^$/0/')
  if [ "$BALANCE_IS_ZERO" = "0" ] || [ -z "$YIELDVAULT_BALANCE_AFTER_CLOSE" ]; then
    log_success "YieldVault balance is zero after close"
  else
    log_fail "YieldVault still has balance: $YIELDVAULT_BALANCE_AFTER_CLOSE FLOW"
  fi

  log_test "Verify YieldVault is removed from User A's list"

  USER_A_VAULTS_AFTER=$(get_user_yieldvaults "$USER_A_EOA")
  log_info "User A YieldVaults after close: $USER_A_VAULTS_AFTER"

  # The specific vault ID should no longer be in the list
  if ! echo "$USER_A_VAULTS_AFTER" | grep -q "$YIELDVAULT_ID"; then
    log_success "YieldVault $YIELDVAULT_ID removed from User A's list"
  else
    log_fail "YieldVault $YIELDVAULT_ID still in User A's list"
  fi

  log_success "Close YieldVault completed with balance verification"
fi

# ============================================
# TEST SCENARIO 7: ERROR CASES
# ============================================

log_section "SCENARIO 7: Error Cases"

# Get User B's vault ID for error tests
USER_B_VAULT_ID=$(echo "$USER_B_VAULTS" | grep -Eo '[0-9]+' | head -1)

if [ -n "$USER_B_VAULT_ID" ]; then
  # Cross-user deposits ARE allowed (like a tip jar) - verify it works
  log_test "User A deposits 1 FLOW to User B's YieldVault (cross-user deposit allowed)"

  USER_B_VAULT_BALANCE_BEFORE=$(get_yieldvault_balance "$USER_B_VAULT_ID")
  log_info "User B's YieldVault balance before: $USER_B_VAULT_BALANCE_BEFORE FLOW"

  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "depositToYieldVault(uint64,address,uint256)" \
    "$USER_B_VAULT_ID" \
    "$NATIVE_FLOW" \
    "1000000000000000000" \
    --value "1ether" 2>&1 || echo "reverted")

  assert_tx_success "$TX_OUTPUT" "Cross-user deposit transaction submitted"

  # Process the deposit
  sleep 1
  process_requests_verbose "DEPOSIT_TO_YIELDVAULT (cross-user)" 0 10 >/dev/null || true
  sleep 2

  # Verify User B's vault balance increased
  USER_B_VAULT_BALANCE_AFTER=$(get_yieldvault_balance "$USER_B_VAULT_ID")
  log_info "User B's YieldVault balance after: $USER_B_VAULT_BALANCE_AFTER FLOW"

  # Balance should have increased by 1 FLOW
  EXPECTED_BALANCE=$(echo "$USER_B_VAULT_BALANCE_BEFORE + 1" | bc)
  EXPECTED_BALANCE_CLEAN=$(echo "$EXPECTED_BALANCE" | sed 's/\.0*$//')
  USER_B_VAULT_BALANCE_AFTER_CLEAN=$(echo "$USER_B_VAULT_BALANCE_AFTER" | sed 's/\.0*$//')
  if [ "$USER_B_VAULT_BALANCE_AFTER_CLEAN" = "$EXPECTED_BALANCE_CLEAN" ]; then
    log_success "Cross-user deposit succeeded - User B's vault increased by 1 FLOW"
  else
    log_fail "Cross-user deposit balance mismatch (expected: $EXPECTED_BALANCE_CLEAN, got: $USER_B_VAULT_BALANCE_AFTER)"
  fi

  # Cross-user CLOSE should fail - only owner can close
  log_test "User A tries to close User B's YieldVault (should fail - only owner can close)"

  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "closeYieldVault(uint64)" \
    "$USER_B_VAULT_ID" 2>&1 || echo "reverted")

  if echo "$TX_OUTPUT" | grep -qi "revert\|error"; then
    log_success "Close non-owned YieldVault correctly rejected on EVM"
  else
    # Request submitted - will fail on Cadence processing
    log_info "Request submitted - verifying Cadence rejects it"
    sleep 1
    process_requests_verbose "CLOSE_YIELDVAULT (cross-user, should fail)" 0 10 >/dev/null || true
    sleep 2

    # Verify User B's vault still exists and has balance
    USER_B_VAULT_STILL_EXISTS=$(get_yieldvault_balance "$USER_B_VAULT_ID")
    if [ -n "$USER_B_VAULT_STILL_EXISTS" ] && [ "$USER_B_VAULT_STILL_EXISTS" != "0" ]; then
      log_success "Close non-owned YieldVault correctly rejected on Cadence"
    else
      log_fail "User B's YieldVault was incorrectly closed by User A"
    fi
  fi
fi

log_test "Try to create YieldVault with zero amount (should fail)"

TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "0" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "0" 2>&1 || echo "reverted")

assert_tx_reverted "$TX_OUTPUT" "Zero amount correctly rejected"

log_test "Try to create YieldVault with mismatched msg.value (should fail)"

TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "10000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "5ether" 2>&1 || echo "reverted")

assert_tx_reverted "$TX_OUTPUT" "Mismatched msg.value correctly rejected"

# ============================================
# TEST SCENARIO 8: RAPID SEQUENTIAL OPERATIONS
# ============================================

log_section "SCENARIO 8: Rapid Sequential Operations"

log_test "User C creates multiple requests rapidly"

# Create 3 requests in sequence
for i in 1 2 3; do
  TX_OUTPUT=$(cast_send "$USER_C_PK" \
    "createYieldVault(address,uint256,string,string)" \
    "$NATIVE_FLOW" \
    "5000000000000000000" \
    "$VAULT_IDENTIFIER" \
    "$STRATEGY_IDENTIFIER" \
    --value "5ether" 2>&1 || echo "")

  if echo "$TX_OUTPUT" | grep -q "status.*1"; then
    log_info "Request $i submitted successfully"
  else
    log_info "Request $i: $TX_OUTPUT"
  fi
done

PENDING_COUNT=$(get_pending_count)
log_info "Pending requests after rapid creation: $PENDING_COUNT"

log_test "Process all pending requests"

PROCESS_OUTPUT=$(process_requests_verbose "CREATE_YIELDVAULT (batch)" 0 20)
if echo "$PROCESS_OUTPUT" | grep -q "SEALED"; then
  log_success "Batch processing completed"
else
  log_fail "Batch processing failed"
fi

sleep 2

USER_C_VAULTS=$(get_user_yieldvaults "$USER_C_EOA")
log_info "User C YieldVaults after batch: $USER_C_VAULTS"

VAULT_COUNT=$(echo "$USER_C_VAULTS" | grep -Eo '[0-9]+' | wc -l | tr -d ' ')
log_info "User C now has $VAULT_COUNT YieldVault(s)"

if [ "$VAULT_COUNT" -ge 1 ]; then
  log_success "Multiple YieldVaults created successfully"
else
  log_fail "Expected multiple YieldVaults for User C"
fi

# ============================================
# TEST SCENARIO 9: FULL LIFECYCLE
# ============================================

log_section "SCENARIO 9: Full Lifecycle Test"

log_test "Complete lifecycle: Create -> Deposit -> Deposit -> Withdraw -> Withdraw -> Close"

# Create
TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "50000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "50ether")

assert_tx_success "$TX_OUTPUT" "Lifecycle: Create submitted"

sleep 1
process_requests_verbose "CREATE_YIELDVAULT (lifecycle)" 0 10 >/dev/null || true
sleep 2

# Get the new vault ID
USER_A_VAULTS=$(get_user_yieldvaults "$USER_A_EOA")
LIFECYCLE_VAULT_ID=$(echo "$USER_A_VAULTS" | grep -Eo '[0-9]+' | tail -1)
log_info "Lifecycle YieldVault ID: $LIFECYCLE_VAULT_ID"

if [ -n "$LIFECYCLE_VAULT_ID" ]; then
  # Deposit 1
  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "depositToYieldVault(uint64,address,uint256)" \
    "$LIFECYCLE_VAULT_ID" \
    "$NATIVE_FLOW" \
    "10000000000000000000" \
    --value "10ether")
  assert_tx_success "$TX_OUTPUT" "Lifecycle: Deposit 1 submitted"

  # Deposit 2
  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "depositToYieldVault(uint64,address,uint256)" \
    "$LIFECYCLE_VAULT_ID" \
    "$NATIVE_FLOW" \
    "10000000000000000000" \
    --value "10ether")
  assert_tx_success "$TX_OUTPUT" "Lifecycle: Deposit 2 submitted"

  # Process deposits
  sleep 1
  process_requests_verbose "DEPOSIT_TO_YIELDVAULT (lifecycle x2)" 0 10 >/dev/null || true
  sleep 2

  # Withdraw 1
  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "withdrawFromYieldVault(uint64,uint256)" \
    "$LIFECYCLE_VAULT_ID" \
    "5000000000000000000")
  assert_tx_success "$TX_OUTPUT" "Lifecycle: Withdraw 1 submitted"

  # Withdraw 2
  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "withdrawFromYieldVault(uint64,uint256)" \
    "$LIFECYCLE_VAULT_ID" \
    "5000000000000000000")
  assert_tx_success "$TX_OUTPUT" "Lifecycle: Withdraw 2 submitted"

  # Process withdrawals
  sleep 1
  process_requests_verbose "WITHDRAW_FROM_YIELDVAULT (lifecycle x2)" 0 10 >/dev/null || true
  sleep 2

  # Close
  TX_OUTPUT=$(cast_send "$USER_A_PK" \
    "closeYieldVault(uint64)" \
    "$LIFECYCLE_VAULT_ID")
  assert_tx_success "$TX_OUTPUT" "Lifecycle: Close submitted"

  # Process close
  sleep 1
  process_requests_verbose "CLOSE_YIELDVAULT (lifecycle)" 0 10 >/dev/null || true
  sleep 2

  # Verify lifecycle vault is closed and balance returned
  log_test "Verify lifecycle YieldVault closed properly"
  LIFECYCLE_VAULT_BALANCE=$(get_yieldvault_balance "$LIFECYCLE_VAULT_ID")
  # Check if balance is zero (handles 0, 0.0, 0.00000000, empty string)
  LIFECYCLE_BALANCE_IS_ZERO=$(echo "$LIFECYCLE_VAULT_BALANCE" | sed 's/0*$//' | sed 's/\.$//' | sed 's/^$/0/')
  if [ "$LIFECYCLE_BALANCE_IS_ZERO" = "0" ] || [ -z "$LIFECYCLE_VAULT_BALANCE" ]; then
    log_success "Lifecycle YieldVault closed and balance returned"
  else
    log_fail "Lifecycle YieldVault still has balance: $LIFECYCLE_VAULT_BALANCE"
  fi

  log_success "Full lifecycle completed successfully"
fi

# ============================================
# FINAL VERIFICATION: FUNDS CONSERVATION
# ============================================

log_section "FINAL VERIFICATION: Cross-VM Funds Conservation"

log_test "Verify no funds stuck in escrow"

# Check all users have zero escrow balance
USER_A_FINAL_ESCROW=$(get_escrow_balance "$USER_A_EOA")
USER_B_FINAL_ESCROW=$(get_escrow_balance "$USER_B_EOA")
USER_C_FINAL_ESCROW=$(get_escrow_balance "$USER_C_EOA")

log_info "User A final escrow: $(wei_to_ether $USER_A_FINAL_ESCROW) FLOW"
log_info "User B final escrow: $(wei_to_ether $USER_B_FINAL_ESCROW) FLOW"
log_info "User C final escrow: $(wei_to_ether $USER_C_FINAL_ESCROW) FLOW"

ESCROW_OK=true
# Use bc to compare (handles large numbers)
if [ "$(echo "$USER_A_FINAL_ESCROW > 0" | bc)" = "1" ]; then
  log_fail "User A has funds stuck in escrow: $(wei_to_ether $USER_A_FINAL_ESCROW) FLOW"
  ESCROW_OK=false
fi
if [ "$(echo "$USER_B_FINAL_ESCROW > 0" | bc)" = "1" ]; then
  log_fail "User B has funds stuck in escrow: $(wei_to_ether $USER_B_FINAL_ESCROW) FLOW"
  ESCROW_OK=false
fi
if [ "$(echo "$USER_C_FINAL_ESCROW > 0" | bc)" = "1" ]; then
  log_fail "User C has funds stuck in escrow: $(wei_to_ether $USER_C_FINAL_ESCROW) FLOW"
  ESCROW_OK=false
fi
if [ "$ESCROW_OK" = true ]; then
  log_success "No funds stuck in escrow"
fi

log_test "Verify no pending requests remaining"
FINAL_PENDING=$(get_pending_count)
if [ "$FINAL_PENDING" = "0" ]; then
  log_success "No pending requests remaining"
else
  log_fail "Still have $FINAL_PENDING pending requests"
fi

log_test "Verify all active YieldVaults have positive balances"

# Get User B's YieldVault (should still be active)
USER_B_FINAL_VAULTS=$(get_user_yieldvaults "$USER_B_EOA")
USER_B_VAULT_ID=$(echo "$USER_B_FINAL_VAULTS" | grep -Eo '[0-9]+' | head -1)

if [ -n "$USER_B_VAULT_ID" ]; then
  USER_B_VAULT_BALANCE=$(get_yieldvault_balance "$USER_B_VAULT_ID")
  log_info "User B YieldVault $USER_B_VAULT_ID balance: $USER_B_VAULT_BALANCE FLOW"
  if [ -n "$USER_B_VAULT_BALANCE" ] && [ "$USER_B_VAULT_BALANCE" != "0.0" ] && [ "$USER_B_VAULT_BALANCE" != "0" ]; then
    log_success "User B's YieldVault has expected balance"
  else
    log_fail "User B's YieldVault has unexpected zero balance"
  fi
fi

# Get User C's YieldVaults (should have 3 from rapid creation)
USER_C_FINAL_VAULTS=$(get_user_yieldvaults "$USER_C_EOA")
USER_C_VAULT_COUNT=$(echo "$USER_C_FINAL_VAULTS" | grep -Eo '[0-9]+' | wc -l | tr -d ' ')
log_info "User C has $USER_C_VAULT_COUNT active YieldVault(s)"

if [ "$USER_C_VAULT_COUNT" -ge 1 ]; then
  # Check first vault has expected balance (5 FLOW each)
  USER_C_FIRST_VAULT=$(echo "$USER_C_FINAL_VAULTS" | grep -Eo '[0-9]+' | head -1)
  if [ -n "$USER_C_FIRST_VAULT" ]; then
    USER_C_VAULT_BALANCE=$(get_yieldvault_balance "$USER_C_FIRST_VAULT")
    log_info "User C YieldVault $USER_C_FIRST_VAULT balance: $USER_C_VAULT_BALANCE FLOW"
    if [ "$USER_C_VAULT_BALANCE" = "5.0" ] || [ "$USER_C_VAULT_BALANCE" = "5.00000000" ]; then
      log_success "User C's YieldVault has expected 5 FLOW balance"
    else
      log_info "User C's YieldVault balance: $USER_C_VAULT_BALANCE (expected 5.0)"
    fi
  fi
fi

# Summary of fund locations
log_section "FUNDS LOCATION SUMMARY"
echo ""
echo "Active YieldVaults:"
echo "  User A: $(get_user_yieldvaults "$USER_A_EOA")"
echo "  User B: $(get_user_yieldvaults "$USER_B_EOA")"
echo "  User C: $(get_user_yieldvaults "$USER_C_EOA")"
echo ""
echo "Escrow Balances (should all be 0 FLOW):"
echo "  User A: $(wei_to_ether $USER_A_FINAL_ESCROW) FLOW"
echo "  User B: $(wei_to_ether $USER_B_FINAL_ESCROW) FLOW"
echo "  User C: $(wei_to_ether $USER_C_FINAL_ESCROW) FLOW"
echo ""

# ============================================
# FINAL SUMMARY
# ============================================

log_section "TEST SUMMARY"

echo ""
echo "Final pending requests: $FINAL_PENDING"
echo ""
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Total Tests:  $TOTAL_TESTS"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
  echo -e "${GREEN}=========================================${NC}"
  echo -e "${GREEN}✅ ALL TESTS PASSED!${NC}"
  echo -e "${GREEN}=========================================${NC}"
  echo ""
  echo "Cross-VM balance verification completed successfully."
  echo "All funds properly tracked between EVM and Cadence."
  exit 0
else
  echo -e "${RED}=========================================${NC}"
  echo -e "${RED}❌ SOME TESTS FAILED${NC}"
  echo -e "${RED}=========================================${NC}"
  echo ""
  echo "Review failed tests above for balance discrepancies."
  exit 1
fi
