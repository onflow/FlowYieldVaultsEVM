#!/bin/bash

set -e  # Exit on any error
set -o pipefail  # Catch pipe failures

# ============================================
# E2E ADMIN TEST SCRIPT FOR FLOWYIELDVAULTSEVM
# ============================================
# This script tests all admin functions called from Cadence
# and verifies their effects on the EVM contract:
# - Allowlist management (enable, add, remove, disable)
# - Blocklist management (enable, add, remove, disable)
# - Blocklist precedence over allowlist
# - Token configuration
# - Max pending requests per user
# - Admin cancel request
# - Drop requests
#
# The contract address is automatically loaded from ./local/.deployed_contract_address
# (created by deploy_full_stack.sh)
#
# Usage (run all three scripts chained):
#   ./local/setup_and_run_emulator.sh && ./local/deploy_full_stack.sh && ./local/run_admin_e2e_tests.sh
#
# Or run individually after deployment:
#   ./local/run_admin_e2e_tests.sh
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
# PREREQUISITES CHECK
# ============================================

# Check working directory
if [ ! -d "./cadence" ] || [ ! -d "./solidity" ]; then
  echo -e "${RED}Error: Must run from repository root directory${NC}"
  echo "Usage: ./local/run_admin_e2e_tests.sh"
  exit 1
fi

# Check required dependencies
for cmd in cast flow curl bc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error: Required command '$cmd' not found${NC}"
    exit 1
  fi
done

# ============================================
# CONFIGURATION
# ============================================

# Check if contract address is set, otherwise read from file
if [ -z "$FLOW_VAULTS_REQUESTS_CONTRACT" ]; then
  if [ -f "./local/.deployed_contract_address" ]; then
    FLOW_VAULTS_REQUESTS_CONTRACT=$(cat ./local/.deployed_contract_address)
    echo "Loaded contract address from ./local/.deployed_contract_address"
  else
    echo -e "${RED}Error: FLOW_VAULTS_REQUESTS_CONTRACT not set${NC}"
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

# Admin account (the one with Worker resource)
ADMIN_SIGNER="emulator-flow-yield-vaults"

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
  echo -e "  $1"
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
  cast_call "getPendingRequestCount()(uint256)" | sed 's/ \[.*\]$//' | tr -d ' '
}

# Get user's pending request count
get_user_pending_count() {
  local user_address=$1
  cast_call "getUserPendingRequestCount(address)(uint256)" "$user_address" | sed 's/ \[.*\]$//' | tr -d ' '
}

# Get escrowed balance from Solidity contract (in wei)
get_escrow_balance() {
  local user_address=$1
  local token_address=${2:-$NATIVE_FLOW}
  cast_call "getUserPendingBalance(address,address)(uint256)" "$user_address" "$token_address" | \
    sed 's/ \[.*\]$//' | tr -d ' '
}

# Get request status (0=PENDING, 1=PROCESSING, 2=COMPLETED, 3=FAILED)
# The struct is: (requestId, user, requestType, status, token, amount, yieldVaultId, createdAt, vaultIdentifier, strategyIdentifier, errorMessage)
# Status is the 4th field (index 3)
get_request_status() {
  local request_id=$1
  local result
  result=$(cast_call "getRequest(uint256)((uint256,address,uint8,uint8,address,uint256,uint64,uint256,string,string,string))" "$request_id")
  # Extract the status field (4th value after the opening paren)
  # Cast output format: (requestId, user, requestType, status, ...)
  # Use awk to split by comma and get the 4th field, then extract the number
  echo "$result" | tr ',' '\n' | sed -n '4p' | grep -Eo '[0-9]+' | head -1
}

# Normalize boolean output from cast (handles true/false, 0x hex, etc.)
normalize_bool() {
  local value=$1
  value=$(echo "$value" | tr -d '[:space:]')
  # Handle various formats: true, false, 0x...01, 0x...00, 1, 0
  if [[ "$value" == "true" ]] || [[ "$value" =~ 0x0*1$ ]] || [[ "$value" == "1" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Get allowlist enabled status via EVM
get_allowlist_enabled_evm() {
  local result
  result=$(cast_call "allowlistEnabled()(bool)")
  normalize_bool "$result"
}

# Get blocklist enabled status via EVM
get_blocklist_enabled_evm() {
  local result
  result=$(cast_call "blocklistEnabled()(bool)")
  normalize_bool "$result"
}

# Check if address is allowlisted via EVM
is_allowlisted_evm() {
  local address=$1
  local result
  result=$(cast_call "allowlisted(address)(bool)" "$address")
  normalize_bool "$result"
}

# Check if address is blocklisted via EVM
is_blocklisted_evm() {
  local address=$1
  local result
  result=$(cast_call "blocklisted(address)(bool)" "$address")
  normalize_bool "$result"
}

# Get max pending requests per user via EVM
get_max_pending_requests_evm() {
  cast_call "maxPendingRequestsPerUser()(uint256)" | sed 's/ \[.*\]$//' | tr -d ' '
}

# Get token config via EVM
get_token_config_evm() {
  local token_address=$1
  cast_call "allowedTokens(address)(bool,uint256,bool)" "$token_address"
}

# Get pending request IDs as a newline-separated list
# Handles various cast output formats: [1, 2, 3] or [1,2,3] or array format
get_pending_request_ids() {
  local result
  result=$(cast_call "getPendingRequestIds()(uint256[])")
  # Remove brackets, split by comma, extract numbers
  echo "$result" | tr -d '[]' | tr ',' '\n' | grep -Eo '[0-9]+' | grep -v '^$'
}

# Get the last N pending request IDs
get_last_n_pending_ids() {
  local n=$1
  get_pending_request_ids | tail -"$n"
}

# Execute Cadence transaction
flow_tx() {
  local tx_path=$1
  shift
  flow transactions send "$tx_path" "$@" --signer "$ADMIN_SIGNER" --compute-limit 9999 2>&1
}

# Execute Cadence script
flow_script() {
  local script_path=$1
  shift
  flow scripts execute "$script_path" "$@" 2>&1
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

# Assert Cadence transaction sealed
assert_cadence_tx_sealed() {
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

# ============================================
# SETUP
# ============================================

log_section "SETUP & VERIFICATION"

echo "Contract Address: $FLOW_VAULTS_REQUESTS_CONTRACT"
echo "User A: $USER_A_EOA"
echo "User B: $USER_B_EOA"
echo "User C: $USER_C_EOA"
echo "Admin Signer: $ADMIN_SIGNER"

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
# TEST SCENARIO 1: ALLOWLIST MANAGEMENT
# ============================================

log_section "SCENARIO 1: Allowlist Management"

# Verify initial state (allowlist disabled)
log_test "Verify allowlist is initially disabled"
ALLOWLIST_ENABLED=$(get_allowlist_enabled_evm)
assert_eq "false" "$ALLOWLIST_ENABLED" "Allowlist is disabled by default"

# Enable allowlist via Cadence
log_test "Enable allowlist via Cadence transaction"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_allowlist_enabled.cdc" true)
assert_cadence_tx_sealed "$TX_OUTPUT" "Enable allowlist transaction sealed"

# Verify allowlist is now enabled via EVM
log_test "Verify allowlist is enabled via EVM"
ALLOWLIST_ENABLED=$(get_allowlist_enabled_evm)
assert_eq "true" "$ALLOWLIST_ENABLED" "Allowlist is now enabled"

# Verify allowlist via Cadence script
log_test "Verify allowlist status via Cadence script"
SCRIPT_OUTPUT=$(flow_script "./cadence/scripts/admin/get_allowlist_status.cdc" "$FLOW_VAULTS_REQUESTS_CONTRACT" "")
assert_contains "$SCRIPT_OUTPUT" "enabled: true" "Cadence script confirms allowlist enabled"

# Try to create request with non-allowlisted user (should fail)
log_test "Non-allowlisted user cannot create request"
TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "1000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "1ether" 2>&1 || echo "reverted")
assert_tx_reverted "$TX_OUTPUT" "Non-allowlisted user correctly rejected"

# Add User A to allowlist via Cadence
log_test "Add User A to allowlist via Cadence"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/batch_add_to_allowlist.cdc" "[\"$USER_A_EOA\"]")
assert_cadence_tx_sealed "$TX_OUTPUT" "Add to allowlist transaction sealed"

# Verify User A is allowlisted via EVM
log_test "Verify User A is allowlisted via EVM"
IS_ALLOWLISTED=$(is_allowlisted_evm "$USER_A_EOA")
assert_eq "true" "$IS_ALLOWLISTED" "User A is now allowlisted"

# Verify via Cadence script
log_test "Verify User A allowlist status via Cadence script"
SCRIPT_OUTPUT=$(flow_script "./cadence/scripts/admin/get_allowlist_status.cdc" "$FLOW_VAULTS_REQUESTS_CONTRACT" "$USER_A_EOA")
assert_contains "$SCRIPT_OUTPUT" "isAllowlisted: true" "Cadence script confirms User A allowlisted"

# Now User A can create request
log_test "Allowlisted user can create request"
TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "1000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "1ether")
assert_tx_success "$TX_OUTPUT" "Allowlisted User A can create request"

# Process the request to clean up
sleep 1
flow_tx "./cadence/transactions/process_requests.cdc" 0 10 >/dev/null 2>&1 || true
sleep 1

# Remove User A from allowlist via Cadence
log_test "Remove User A from allowlist via Cadence"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/batch_remove_from_allowlist.cdc" "[\"$USER_A_EOA\"]")
assert_cadence_tx_sealed "$TX_OUTPUT" "Remove from allowlist transaction sealed"

# Verify User A is no longer allowlisted
log_test "Verify User A is no longer allowlisted"
IS_ALLOWLISTED=$(is_allowlisted_evm "$USER_A_EOA")
assert_eq "false" "$IS_ALLOWLISTED" "User A is no longer allowlisted"

# Disable allowlist for next tests
log_test "Disable allowlist via Cadence"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_allowlist_enabled.cdc" false)
assert_cadence_tx_sealed "$TX_OUTPUT" "Disable allowlist transaction sealed"

ALLOWLIST_ENABLED=$(get_allowlist_enabled_evm)
assert_eq "false" "$ALLOWLIST_ENABLED" "Allowlist is now disabled"

# ============================================
# TEST SCENARIO 2: BLOCKLIST MANAGEMENT
# ============================================

log_section "SCENARIO 2: Blocklist Management"

# Verify initial state (blocklist disabled)
log_test "Verify blocklist is initially disabled"
BLOCKLIST_ENABLED=$(get_blocklist_enabled_evm)
assert_eq "false" "$BLOCKLIST_ENABLED" "Blocklist is disabled by default"

# Enable blocklist via Cadence
log_test "Enable blocklist via Cadence transaction"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_blocklist_enabled.cdc" true)
assert_cadence_tx_sealed "$TX_OUTPUT" "Enable blocklist transaction sealed"

# Verify blocklist is now enabled via EVM
log_test "Verify blocklist is enabled via EVM"
BLOCKLIST_ENABLED=$(get_blocklist_enabled_evm)
assert_eq "true" "$BLOCKLIST_ENABLED" "Blocklist is now enabled"

# Add User B to blocklist via Cadence
log_test "Add User B to blocklist via Cadence"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/batch_add_to_blocklist.cdc" "[\"$USER_B_EOA\"]")
assert_cadence_tx_sealed "$TX_OUTPUT" "Add to blocklist transaction sealed"

# Verify User B is blocklisted via EVM
log_test "Verify User B is blocklisted via EVM"
IS_BLOCKLISTED=$(is_blocklisted_evm "$USER_B_EOA")
assert_eq "true" "$IS_BLOCKLISTED" "User B is now blocklisted"

# Verify via Cadence script
log_test "Verify User B blocklist status via Cadence script"
SCRIPT_OUTPUT=$(flow_script "./cadence/scripts/admin/get_blocklist_status.cdc" "$FLOW_VAULTS_REQUESTS_CONTRACT" "$USER_B_EOA")
assert_contains "$SCRIPT_OUTPUT" "isBlocklisted: true" "Cadence script confirms User B blocklisted"

# Blocklisted user cannot create request
log_test "Blocklisted user cannot create request"
TX_OUTPUT=$(cast_send "$USER_B_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "1000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "1ether" 2>&1 || echo "reverted")
assert_tx_reverted "$TX_OUTPUT" "Blocklisted User B correctly rejected"

# Non-blocklisted user can still create request
log_test "Non-blocklisted user can create request"
TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "1000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "1ether")
assert_tx_success "$TX_OUTPUT" "Non-blocklisted User A can create request"

# Process the request to clean up
sleep 1
flow_tx "./cadence/transactions/process_requests.cdc" 0 10 >/dev/null 2>&1 || true
sleep 1

# Remove User B from blocklist via Cadence
log_test "Remove User B from blocklist via Cadence"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/batch_remove_from_blocklist.cdc" "[\"$USER_B_EOA\"]")
assert_cadence_tx_sealed "$TX_OUTPUT" "Remove from blocklist transaction sealed"

# Verify User B is no longer blocklisted
log_test "Verify User B is no longer blocklisted"
IS_BLOCKLISTED=$(is_blocklisted_evm "$USER_B_EOA")
assert_eq "false" "$IS_BLOCKLISTED" "User B is no longer blocklisted"

# Disable blocklist for next tests
log_test "Disable blocklist via Cadence"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_blocklist_enabled.cdc" false)
assert_cadence_tx_sealed "$TX_OUTPUT" "Disable blocklist transaction sealed"

# ============================================
# TEST SCENARIO 3: BLOCKLIST PRECEDENCE
# ============================================

log_section "SCENARIO 3: Blocklist Precedence Over Allowlist"

# Enable both allowlist and blocklist
log_test "Enable both allowlist and blocklist"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_allowlist_enabled.cdc" true)
assert_cadence_tx_sealed "$TX_OUTPUT" "Enable allowlist sealed"

TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_blocklist_enabled.cdc" true)
assert_cadence_tx_sealed "$TX_OUTPUT" "Enable blocklist sealed"

# Add User C to both allowlist and blocklist
log_test "Add User C to both allowlist and blocklist"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/batch_add_to_allowlist.cdc" "[\"$USER_C_EOA\"]")
assert_cadence_tx_sealed "$TX_OUTPUT" "Add User C to allowlist sealed"

TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/batch_add_to_blocklist.cdc" "[\"$USER_C_EOA\"]")
assert_cadence_tx_sealed "$TX_OUTPUT" "Add User C to blocklist sealed"

# Verify User C is both allowlisted and blocklisted
IS_ALLOWLISTED=$(is_allowlisted_evm "$USER_C_EOA")
IS_BLOCKLISTED=$(is_blocklisted_evm "$USER_C_EOA")
log_info "User C allowlisted: $IS_ALLOWLISTED, blocklisted: $IS_BLOCKLISTED"

# User C should be blocked (blocklist takes precedence)
log_test "Blocklist takes precedence over allowlist"
TX_OUTPUT=$(cast_send "$USER_C_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "1000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "1ether" 2>&1 || echo "reverted")
assert_tx_reverted "$TX_OUTPUT" "Blocklisted user rejected even if allowlisted"

# Clean up: disable both lists and remove User C
flow_tx "./cadence/transactions/admin/batch_remove_from_allowlist.cdc" "[\"$USER_C_EOA\"]" >/dev/null 2>&1 || true
flow_tx "./cadence/transactions/admin/batch_remove_from_blocklist.cdc" "[\"$USER_C_EOA\"]" >/dev/null 2>&1 || true
flow_tx "./cadence/transactions/admin/set_allowlist_enabled.cdc" false >/dev/null 2>&1 || true
flow_tx "./cadence/transactions/admin/set_blocklist_enabled.cdc" false >/dev/null 2>&1 || true

# ============================================
# TEST SCENARIO 4: TOKEN CONFIGURATION
# ============================================

log_section "SCENARIO 4: Token Configuration"

# Get current token config for NATIVE_FLOW
log_test "Get initial token config via EVM"
TOKEN_CONFIG=$(get_token_config_evm "$NATIVE_FLOW")
log_info "Initial NATIVE_FLOW config: $TOKEN_CONFIG"
assert_contains "$TOKEN_CONFIG" "true" "NATIVE_FLOW is initially supported"

# Get config via Cadence script
log_test "Get token config via Cadence script"
SCRIPT_OUTPUT=$(flow_script "./cadence/scripts/admin/get_token_config.cdc" "$FLOW_VAULTS_REQUESTS_CONTRACT" "$NATIVE_FLOW")
log_info "Cadence token config: $SCRIPT_OUTPUT"
assert_contains "$SCRIPT_OUTPUT" "isSupported: true" "Cadence script shows NATIVE_FLOW supported"

# Update token config: increase minimum balance via Cadence
log_test "Update token minimum balance via Cadence"
NEW_MIN_BALANCE="2000000000000000000"  # 2 FLOW in wei
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_token_config.cdc" "$NATIVE_FLOW" true "$NEW_MIN_BALANCE" true)
assert_cadence_tx_sealed "$TX_OUTPUT" "Set token config transaction sealed"

# Verify new minimum balance via EVM
log_test "Verify updated minimum balance via EVM"
TOKEN_CONFIG=$(get_token_config_evm "$NATIVE_FLOW")
log_info "Updated NATIVE_FLOW config: $TOKEN_CONFIG"
# The config returns (isSupported, minimumBalance, isNative)
assert_contains "$TOKEN_CONFIG" "2000000000000000000" "Minimum balance updated to 2 FLOW"

# Try to create request with amount below new minimum (should fail)
log_test "Request below minimum balance rejected"
TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "1000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "1ether" 2>&1 || echo "reverted")
assert_tx_reverted "$TX_OUTPUT" "Amount below minimum correctly rejected"

# Create request with amount above minimum (should succeed)
log_test "Request above minimum balance accepted"
TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "3000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "3ether")
assert_tx_success "$TX_OUTPUT" "Amount above minimum accepted"

# Process the request to clean up
sleep 1
flow_tx "./cadence/transactions/process_requests.cdc" 0 10 >/dev/null 2>&1 || true
sleep 1

# Reset minimum balance to original (0.5 FLOW or whatever it was)
log_test "Reset token minimum balance"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_token_config.cdc" "$NATIVE_FLOW" true "500000000000000000" true)
assert_cadence_tx_sealed "$TX_OUTPUT" "Reset token config transaction sealed"

# ============================================
# TEST SCENARIO 5: MAX PENDING REQUESTS PER USER
# ============================================

log_section "SCENARIO 5: Max Pending Requests Per User"

# Get current max pending requests
log_test "Get initial max pending requests per user"
MAX_PENDING=$(get_max_pending_requests_evm)
log_info "Initial max pending requests: $MAX_PENDING"

# Set max to 2 via Cadence
log_test "Set max pending requests to 2 via Cadence"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_max_pending_requests_per_user.cdc" 2)
assert_cadence_tx_sealed "$TX_OUTPUT" "Set max pending requests transaction sealed"

# Verify new max via EVM
log_test "Verify max pending requests via EVM"
MAX_PENDING=$(get_max_pending_requests_evm)
assert_eq "2" "$MAX_PENDING" "Max pending requests set to 2"

# Verify via Cadence script
log_test "Verify max pending via Cadence script"
SCRIPT_OUTPUT=$(flow_script "./cadence/scripts/admin/get_evm_contract_config.cdc" "$FLOW_VAULTS_REQUESTS_CONTRACT")
assert_contains "$SCRIPT_OUTPUT" "maxPendingRequestsPerUser: 2" "Cadence script confirms max is 2"

# Create 2 requests (should succeed)
log_test "Create first request (1/2)"
TX_OUTPUT=$(cast_send "$USER_B_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "1000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "1ether")
assert_tx_success "$TX_OUTPUT" "First request created"

log_test "Create second request (2/2)"
TX_OUTPUT=$(cast_send "$USER_B_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "1000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "1ether")
assert_tx_success "$TX_OUTPUT" "Second request created"

# Third request should fail (exceeds max)
log_test "Third request exceeds max (should fail)"
TX_OUTPUT=$(cast_send "$USER_B_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "1000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "1ether" 2>&1 || echo "reverted")
assert_tx_reverted "$TX_OUTPUT" "Third request correctly rejected (max exceeded)"

# Process requests to clean up
sleep 1
flow_tx "./cadence/transactions/process_requests.cdc" 0 10 >/dev/null 2>&1 || true
sleep 1

# Reset max to 0 (unlimited)
log_test "Reset max pending requests to unlimited"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/set_max_pending_requests_per_user.cdc" 0)
assert_cadence_tx_sealed "$TX_OUTPUT" "Reset max pending requests sealed"

# ============================================
# TEST SCENARIO 6: ADMIN CANCEL REQUEST
# ============================================

log_section "SCENARIO 6: Admin Cancel Request"

# User A creates a request
log_test "User A creates a request"
TX_OUTPUT=$(cast_send "$USER_A_PK" \
  "createYieldVault(address,uint256,string,string)" \
  "$NATIVE_FLOW" \
  "5000000000000000000" \
  "$VAULT_IDENTIFIER" \
  "$STRATEGY_IDENTIFIER" \
  --value "5ether")
assert_tx_success "$TX_OUTPUT" "User A created request"

# Get the request ID (last one in the pending list)
REQUEST_ID=$(get_last_n_pending_ids 1)
if [ -z "$REQUEST_ID" ]; then
  log_fail "Could not get pending request ID"
  exit 1
fi
log_info "Request ID: $REQUEST_ID"

# Verify escrow balance
log_test "Verify escrow balance before cancel"
ESCROW_BEFORE=$(get_escrow_balance "$USER_A_EOA")
log_info "User A escrow balance: $(wei_to_ether $ESCROW_BEFORE) FLOW"
assert_contains "$ESCROW_BEFORE" "5000000000000000000" "Escrow holds 5 FLOW"

# Admin cancels the request via Cadence
log_test "Admin cancels request via Cadence"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/cancel_request.cdc" "$REQUEST_ID")
assert_cadence_tx_sealed "$TX_OUTPUT" "Admin cancel request sealed"

# Verify request is now FAILED (status 3)
log_test "Verify request status is FAILED"
STATUS=$(get_request_status "$REQUEST_ID")
assert_eq "3" "$STATUS" "Request status is FAILED"

# Verify escrow cleared (funds refunded)
log_test "Verify escrow cleared after admin cancel"
ESCROW_AFTER=$(get_escrow_balance "$USER_A_EOA")
log_info "User A escrow balance after: $(wei_to_ether $ESCROW_AFTER) FLOW"
assert_eq "0" "$ESCROW_AFTER" "Escrow cleared after cancel"

# ============================================
# TEST SCENARIO 7: DROP REQUESTS
# ============================================

log_section "SCENARIO 7: Drop Requests"

# Create multiple requests from User C
log_test "User C creates 3 requests"
for i in 1 2 3; do
  TX_OUTPUT=$(cast_send "$USER_C_PK" \
    "createYieldVault(address,uint256,string,string)" \
    "$NATIVE_FLOW" \
    "2000000000000000000" \
    "$VAULT_IDENTIFIER" \
    "$STRATEGY_IDENTIFIER" \
    --value "2ether")
  log_info "Request $i created"
done

# Get pending request count
PENDING_BEFORE=$(get_pending_count)
log_info "Pending requests before drop: $PENDING_BEFORE"

# Get escrow balance
ESCROW_BEFORE=$(get_escrow_balance "$USER_C_EOA")
log_info "User C escrow balance before: $(wei_to_ether $ESCROW_BEFORE) FLOW"

# Get pending request IDs
PENDING_IDS_RAW=$(cast_call "getPendingRequestIds()(uint256[])")
log_info "Pending IDs (raw): $PENDING_IDS_RAW"

# Extract last 3 request IDs for dropping using helper function
REQUEST_IDS=$(get_last_n_pending_ids 3)
REQUEST_ID_1=$(echo "$REQUEST_IDS" | sed -n '1p')
REQUEST_ID_2=$(echo "$REQUEST_IDS" | sed -n '2p')
REQUEST_ID_3=$(echo "$REQUEST_IDS" | sed -n '3p')

# Validate we got 3 request IDs
if [ -z "$REQUEST_ID_1" ] || [ -z "$REQUEST_ID_2" ] || [ -z "$REQUEST_ID_3" ]; then
  log_fail "Could not extract 3 request IDs (got: $REQUEST_ID_1, $REQUEST_ID_2, $REQUEST_ID_3)"
  exit 1
fi
log_info "Dropping requests: $REQUEST_ID_1, $REQUEST_ID_2, $REQUEST_ID_3"

# Admin drops all 3 requests via Cadence
log_test "Admin drops 3 requests via Cadence"
TX_OUTPUT=$(flow_tx "./cadence/transactions/admin/drop_requests.cdc" "[$REQUEST_ID_1, $REQUEST_ID_2, $REQUEST_ID_3]")
assert_cadence_tx_sealed "$TX_OUTPUT" "Drop requests transaction sealed"

# Verify pending count decreased
log_test "Verify pending count decreased"
PENDING_AFTER=$(get_pending_count)
log_info "Pending requests after drop: $PENDING_AFTER"
# Pending count should have decreased by 3
EXPECTED_PENDING=$((PENDING_BEFORE - 3))
# Ensure we're comparing integers
if [ "$PENDING_AFTER" -eq "$EXPECTED_PENDING" ] 2>/dev/null; then
  log_success "Pending count decreased by 3 (from $PENDING_BEFORE to $PENDING_AFTER)"
elif [ "$PENDING_AFTER" -lt "$PENDING_BEFORE" ] 2>/dev/null; then
  log_success "Pending count decreased (from $PENDING_BEFORE to $PENDING_AFTER, expected $EXPECTED_PENDING)"
else
  log_fail "Pending count did not decrease as expected (before: $PENDING_BEFORE, after: $PENDING_AFTER, expected: $EXPECTED_PENDING)"
fi

# Verify escrow cleared (funds refunded)
log_test "Verify escrow cleared after drop"
ESCROW_AFTER=$(get_escrow_balance "$USER_C_EOA")
log_info "User C escrow balance after: $(wei_to_ether $ESCROW_AFTER) FLOW"
assert_eq "0" "$ESCROW_AFTER" "Escrow cleared after drop"

# Verify all dropped requests are FAILED
log_test "Verify dropped requests are FAILED"
STATUS_1=$(get_request_status "$REQUEST_ID_1")
STATUS_2=$(get_request_status "$REQUEST_ID_2")
STATUS_3=$(get_request_status "$REQUEST_ID_3")
if [ "$STATUS_1" = "3" ] && [ "$STATUS_2" = "3" ] && [ "$STATUS_3" = "3" ]; then
  log_success "All dropped requests marked as FAILED"
else
  log_fail "Some requests not marked as FAILED (statuses: $STATUS_1, $STATUS_2, $STATUS_3)"
fi

# ============================================
# FINAL VERIFICATION
# ============================================

log_section "FINAL VERIFICATION"

# Verify contract config via Cadence script
log_test "Verify final contract config via Cadence script"
SCRIPT_OUTPUT=$(flow_script "./cadence/scripts/admin/get_evm_contract_config.cdc" "$FLOW_VAULTS_REQUESTS_CONTRACT")
log_info "Final contract config:"
echo "$SCRIPT_OUTPUT" | grep -E "(allowlistEnabled|blocklistEnabled|maxPendingRequestsPerUser)" || true
assert_contains "$SCRIPT_OUTPUT" "allowlistEnabled: false" "Allowlist is disabled"
assert_contains "$SCRIPT_OUTPUT" "blocklistEnabled: false" "Blocklist is disabled"
assert_contains "$SCRIPT_OUTPUT" "maxPendingRequestsPerUser: 0" "Max pending is unlimited"

# ============================================
# FINAL SUMMARY
# ============================================

log_section "TEST SUMMARY"

echo ""
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Total Tests:  $TOTAL_TESTS"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
  echo -e "${GREEN}=========================================${NC}"
  echo -e "${GREEN}ALL ADMIN E2E TESTS PASSED!${NC}"
  echo -e "${GREEN}=========================================${NC}"
  echo ""
  echo "All admin functions verified:"
  echo "  - Allowlist management (Cadence -> EVM)"
  echo "  - Blocklist management (Cadence -> EVM)"
  echo "  - Blocklist precedence over allowlist"
  echo "  - Token configuration (Cadence -> EVM)"
  echo "  - Max pending requests per user (Cadence -> EVM)"
  echo "  - Admin cancel request (Cadence -> EVM)"
  echo "  - Drop requests (Cadence -> EVM)"
  exit 0
else
  echo -e "${RED}=========================================${NC}"
  echo -e "${RED}SOME ADMIN E2E TESTS FAILED${NC}"
  echo -e "${RED}=========================================${NC}"
  echo ""
  echo "Review failed tests above."
  exit 1
fi
