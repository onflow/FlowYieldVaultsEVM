#!/bin/bash
# =============================================================================
# Testnet E2E Testing Script for FlowYieldVaultsEVM
# =============================================================================
#
# PURPOSE:
# --------
# This script provides end-to-end testing capabilities for the FlowYieldVaultsEVM
# cross-VM bridge on Flow Testnet. It allows developers to quickly verify that
# the complete request lifecycle works correctly across both EVM and Cadence layers.
#
# WHY E2E TESTING ON TESTNET?
# ---------------------------
# 1. Cross-VM Verification: The FlowYieldVaultsEVM system spans two virtual machines
#    (EVM and Cadence). Unit tests on each layer don't catch integration issues
#    like bridging failures, COA authorization problems, or state sync errors.
#
# 2. Real Transaction Processing: The TransactionHandler processes requests
#    asynchronously via Flow's transaction scheduler. This behavior can only be
#    fully tested on a live network where the scheduler is active.
#
# 3. Parameter Validation: Testing with invalid vaultIdentifier or strategyIdentifier
#    values helps verify error handling and fund refund mechanisms work correctly.
#
# 4. Balance Reconciliation: Ensures funds flow correctly:
#    - User wallet -> Contract escrow -> COA bridge -> Cadence YieldVault
#    - And back on withdrawals/failures
#
# WHAT THIS SCRIPT TESTS:
# -----------------------
# - State queries: Check balances, pending requests, and YieldVault status
# - Request creation: Send createYieldVault with Native FLOW or WFLOW
# - Request lifecycle: Track requests from PENDING -> PROCESSING -> COMPLETED/FAILED
# - Error scenarios: Test with invalid parameters to verify refund mechanisms
#
# =============================================================================
# VALID PARAMETERS (Testnet)
# =============================================================================
#
# vaultIdentifier:    A.7e60df042a9c0868.FlowToken.Vault
#                     (The Cadence type for FlowToken vault on testnet)
#
# strategyIdentifier: A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.mUSDCStrategy
#                     (The Cadence type for mUSDC yield strategy on testnet)
#
# These identifiers follow the Cadence type format: A.<address>.<contract>.<type>
# Using invalid identifiers will cause the request to fail during processing.
#
# =============================================================================
# TEST SCENARIOS
# =============================================================================
#
# SCENARIO 1: CORRECT PARAMETERS (Happy Path)
# --------------------------------------------
# When vaultIdentifier and strategyIdentifier are valid Cadence types:
#
#   ./local/testnet-e2e.sh create-flow 1.2
#   ./local/testnet-e2e.sh create-wflow 1.3
#
# Expected behavior:
#   1. Request created with status PENDING
#   2. TransactionHandler picks up request (~3-30s depending on queue)
#   3. Worker validates parameters on Cadence side
#   4. COA bridges funds from EVM to Cadence
#   5. YieldVault created with deposited funds
#   6. Request marked as COMPLETED with success message
#   7. New YieldVault ID assigned and mapped to EVM user
#
# Balance changes:
#   - User wallet:      -amount (+ gas fees)
#   - Pending balance:  unchanged (deposit added then deducted during processing)
#   - Contract balance: 0 (funds bridged to Cadence)
#   - YieldVault:       +amount (minus small bridging fee ~0.0002 FLOW)
#
# SCENARIO 2: INVALID PARAMETERS (Error Handling)
# ------------------------------------------------
# When vaultIdentifier or strategyIdentifier are invalid:
#
#   # Invalid vault, correct strategy
#   ./local/testnet-e2e.sh create-flow 1.5 "InvalidVault" "A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.mUSDCStrategy"
#
#   # Correct vault, invalid strategy
#   ./local/testnet-e2e.sh create-flow 1.7 "A.7e60df042a9c0868.FlowToken.Vault" "InvalidStrategy"
#
# Expected behavior:
#   1. Request created with status PENDING (EVM contract doesn't validate identifiers)
#   2. SchedulerHandler picks up request
#   4. Preprocessing: preprocessRequests() attempts to parse identifiers on Cadence side
#   5. Validation fails: "Invalid vaultIdentifier/strategyIdentifier: X is not a valid Cadence type"
#   6. PENDING -> FAILED
#   7. No YieldVault created, yieldVaultId set to NO_YIELDVAULT_ID (max uint64)
#
# Balance changes:
#   - User wallet:      -amount (+ gas fees) - funds left wallet
#   - Pending balance:  0 (escrow was deducted at startProcessingBatch)
#   - Contract balance: +amount (funds returned by COA during completeProcessing)
#   - COA balance:      unchanged (funds returned to contract)
#   - YieldVault:       none created
#
# REFUND MECHANISM:
# -----------------
# When a CREATE/DEPOSIT request fails/panics after PROCESSING state:
#   1. PROCESSING state transfers funds: Contract -> COA
#   2. SchedulerHandler detects validation failure in case of panic
#   3. completeProcessing(FAILED) is called with refund:
#      - Native FLOW: COA sends funds back via msg.value
#      - ERC20 (WFLOW): COA approves contract, then contract pulls via transferFrom
#   4. Contract receives funds and credits claimableRefunds
#   5. User can claim the refund via claimRefund()
#
# =============================================================================
# TYPICAL TEST FLOW
# =============================================================================
#
# 1. Check initial state:        ./local/testnet-e2e.sh state
# 2. Send test transaction:      ./local/testnet-e2e.sh create-flow 1.2
# 3. Wait for processing (~5-30s depending on pending queue)
# 4. Check request status:       ./local/testnet-e2e.sh request <id>
# 5. Verify final state:         ./local/testnet-e2e.sh state
# 6. Check YieldVault balances:  ./local/testnet-e2e.sh user-yieldvaults
#
# =============================================================================
# Usage:
#   ./local/testnet-e2e.sh state              # Check current state
#   ./local/testnet-e2e.sh create-flow <amount> [vault] [strategy]
#   ./local/testnet-e2e.sh create-wflow <amount> [vault] [strategy]
#   ./local/testnet-e2e.sh request <id>       # Get request details
#   ./local/testnet-e2e.sh yieldvault <id>    # Get YieldVault balance
#   ./local/testnet-e2e.sh user-yieldvaults   # List user's YieldVaults
# =============================================================================

set -e

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

# Configuration
RPC_URL="${TESTNET_RPC_URL:-https://testnet.evm.nodes.onflow.org}"
CONTRACT="${CONTRACT:-}"
CADENCE_CONTRACT="${CADENCE_CONTRACT:-}"
WFLOW="0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e"
NATIVE_FLOW="0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF"
DEFAULT_CONTRACT="0xF633C9dBf1a3964a895fCC4CA4404B6f8BA8141d"
DEFAULT_CADENCE_CONTRACT="0x764bdff06a0ee77e"
REFUND_CHECK_MAX_ATTEMPTS="${REFUND_CHECK_MAX_ATTEMPTS:-60}"
REFUND_CHECK_DELAY_SECONDS="${REFUND_CHECK_DELAY_SECONDS:-5}"

# Default correct parameters
DEFAULT_VAULT="A.7e60df042a9c0868.FlowToken.Vault"
DEFAULT_STRATEGY="A.d2580caf2ef07c2f.FlowYieldVaultsStrategies.mUSDCStrategy"

# Get user address from private key
if [ -n "$PRIVATE_KEY" ]; then
    USER=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

load_contract_addresses() {
    local addresses_file="$PROJECT_DIR/deployments/contract-addresses.json"
    if [ ! -f "$addresses_file" ]; then
        return 0
    fi

    local evm_addr=""
    local cadence_addr=""

    if command -v python3 >/dev/null 2>&1; then
        local parsed
        parsed=$(python3 - "$addresses_file" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
    evm = data.get("contracts", {}).get("FlowYieldVaultsRequests", {}).get("addresses", {}).get("testnet", "")
    cadence = data.get("contracts", {}).get("FlowYieldVaultsEVM", {}).get("addresses", {}).get("testnet", "")
    print(evm)
    print(cadence)
except Exception:
    pass
PY
)
        evm_addr=$(printf '%s\n' "$parsed" | sed -n '1p')
        cadence_addr=$(printf '%s\n' "$parsed" | sed -n '2p')
    elif command -v jq >/dev/null 2>&1; then
        evm_addr=$(jq -r '.contracts.FlowYieldVaultsRequests.addresses.testnet // empty' "$addresses_file")
        cadence_addr=$(jq -r '.contracts.FlowYieldVaultsEVM.addresses.testnet // empty' "$addresses_file")
    fi

    if [ -z "$CONTRACT" ] && [ -n "$evm_addr" ]; then
        CONTRACT="$evm_addr"
    fi
    if [ -z "$CADENCE_CONTRACT" ] && [ -n "$cadence_addr" ]; then
        CADENCE_CONTRACT="$cadence_addr"
    fi
}

load_contract_addresses

if [ -z "$CONTRACT" ]; then
    CONTRACT="$DEFAULT_CONTRACT"
fi

if [ -z "$CADENCE_CONTRACT" ]; then
    CADENCE_CONTRACT="$DEFAULT_CADENCE_CONTRACT"
fi

extract_tx_hash() {
    echo "$1" | grep -oE '0x[a-fA-F0-9]{64}' | head -n1
}

get_request_status() {
    local request_id=$1
    local result=$(cast call "$CONTRACT" "getRequest(uint256)((uint256,address,uint8,uint8,address,uint256,uint64,uint256,string,string,string))" "$request_id" --rpc-url "$RPC_URL")
    echo "$result" | sed 's/[()]//g' | cut -d',' -f4 | tr -d ' '
}

status_label() {
    case $1 in
        0) echo "PENDING" ;;
        1) echo "PROCESSING" ;;
        2) echo "COMPLETED" ;;
        3) echo "FAILED" ;;
        *) echo "UNKNOWN" ;;
    esac
}

wait_for_request_status() {
    local request_id=$1
    local target_status=$2
    local max_attempts="${3:-30}"
    local delay_seconds="${4:-5}"

    for ((i = 1; i <= max_attempts; i++)); do
        local status=$(get_request_status "$request_id")
        local label=$(status_label "$status")
        echo "Status: $label ($i/$max_attempts)"

        if [ "$status" = "$target_status" ]; then
            return 0
        fi

        if [ "$status" = "2" ] && [ "$target_status" = "3" ]; then
            print_error "Request completed successfully; refund not expected."
            return 1
        fi

        sleep "$delay_seconds"
    done

    print_error "Timed out waiting for status $(status_label "$target_status")."
    return 1
}

extract_request_id() {
    local tx_hash=$1
    local receipt_json
    receipt_json=$(cast receipt "$tx_hash" --json --rpc-url "$RPC_URL")

    if command -v python3 >/dev/null 2>&1; then
        printf '%s\n' "$receipt_json" | python3 - <<'PY' 2>/dev/null || true
import json, sys
data = json.load(sys.stdin)
for log in data.get("logs", []):
    topics = log.get("topics") or []
    if len(topics) == 4:
        print(int(topics[1], 16))
        sys.exit(0)
sys.exit(1)
PY
        return 0
    fi

    if command -v jq >/dev/null 2>&1; then
        local request_id_hex
        request_id_hex=$(printf '%s\n' "$receipt_json" | jq -r '.logs[] | select(.topics|length==4) | .topics[1]' | head -n1)
        if [ -n "$request_id_hex" ] && [ "$request_id_hex" != "null" ]; then
            printf "%d\n" "$request_id_hex"
        fi
        return 0
    fi

    print_error "python3 or jq is required to extract requestId from the receipt."
    return 1
}

# Convert wei to ether for display
wei_to_ether() {
    local wei=${1:-0}
    echo "scale=8; $wei / 1000000000000000000" | bc
}

# Convert ether to wei
ether_to_wei() {
    local ether=$1
    echo "scale=0; $ether * 1000000000000000000 / 1" | bc
}

# Validate that input is a valid number (integer or decimal)
validate_amount() {
    local amount=$1
    if ! [[ "$amount" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        print_error "Invalid amount: $amount (must be a positive number)"
        exit 1
    fi
}

# =============================================================================
# State Checking Functions
# =============================================================================

check_evm_state() {
    print_header "EVM State"

    echo -e "\n${YELLOW}User: $USER${NC}"

    # User balances
    local user_flow=$(cast balance "$USER" --rpc-url "$RPC_URL")
    local user_wflow=$(cast call "$WFLOW" "balanceOf(address)(uint256)" "$USER" --rpc-url "$RPC_URL")

    echo "User Native FLOW:  $(wei_to_ether $user_flow) FLOW"
    echo "User WFLOW:        $(wei_to_ether $user_wflow) WFLOW"

    # Pending balances (escrow for active requests)
    local pending_flow=$(cast call "$CONTRACT" "getUserPendingBalance(address,address)(uint256)" "$USER" "$NATIVE_FLOW" --rpc-url "$RPC_URL")
    local pending_wflow=$(cast call "$CONTRACT" "getUserPendingBalance(address,address)(uint256)" "$USER" "$WFLOW" --rpc-url "$RPC_URL")

    echo "Pending FLOW:      $(wei_to_ether $pending_flow) FLOW"
    echo "Pending WFLOW:     $(wei_to_ether $pending_wflow) WFLOW"

    # Claimable refunds (available via claimRefund)
    local claimable_flow=$(cast call "$CONTRACT" "getClaimableRefund(address,address)(uint256)" "$USER" "$NATIVE_FLOW" --rpc-url "$RPC_URL")
    local claimable_wflow=$(cast call "$CONTRACT" "getClaimableRefund(address,address)(uint256)" "$USER" "$WFLOW" --rpc-url "$RPC_URL")

    echo "Claimable FLOW:    $(wei_to_ether $claimable_flow) FLOW"
    echo "Claimable WFLOW:   $(wei_to_ether $claimable_wflow) WFLOW"

    # Contract balances (actual funds held by EVM contract)
    local contract_flow=$(cast balance "$CONTRACT" --rpc-url "$RPC_URL")
    local contract_wflow=$(cast call "$WFLOW" "balanceOf(address)(uint256)" "$CONTRACT" --rpc-url "$RPC_URL")

    echo ""
    echo "Contract FLOW:     $(wei_to_ether $contract_flow) FLOW"
    echo "Contract WFLOW:    $(wei_to_ether $contract_wflow) WFLOW"

    # COA balances (funds bridged to Cadence side)
    local coa_address=$(cast call "$CONTRACT" "authorizedCOA()(address)" --rpc-url "$RPC_URL")
    local coa_flow=$(cast balance "$coa_address" --rpc-url "$RPC_URL")

    echo ""
    echo -e "${YELLOW}COA: $coa_address${NC}"
    echo "COA FLOW:          $(wei_to_ether $coa_flow) FLOW"

    # Pending requests count
    local pending_count=$(cast call "$CONTRACT" "getPendingRequestCount()(uint256)" --rpc-url "$RPC_URL")
    echo ""
    echo "Pending Requests:  $pending_count"
}

check_cadence_state() {
    print_header "Cadence State"

    cd "$PROJECT_DIR"

    # Pending requests for user
    echo -e "\n${YELLOW}Pending Requests for EVM User:${NC}"
    flow scripts execute cadence/scripts/get_pending_requests_for_evm_address.cdc "$USER" --network testnet

    # User's YieldVaults
    echo -e "\n${YELLOW}User's YieldVaults:${NC}"
    flow scripts execute cadence/scripts/check_user_yieldvaults.cdc "$USER" --network testnet
}

check_full_state() {
    check_evm_state
    check_cadence_state
}

# =============================================================================
# Transaction Functions
# =============================================================================

create_yieldvault_flow() {
    local amount=$1
    shift

    # Parse remaining arguments, looking for multiplier (x100) pattern
    local vault="$DEFAULT_VAULT"
    local strategy="$DEFAULT_STRATEGY"
    local count=1

    for arg in "$@"; do
        if [[ "$arg" =~ ^x([0-9]+)$ ]]; then
            count="${BASH_REMATCH[1]}"
        elif [ "$vault" = "$DEFAULT_VAULT" ] && [ -n "$arg" ]; then
            vault="$arg"
        elif [ "$strategy" = "$DEFAULT_STRATEGY" ] && [ -n "$arg" ]; then
            strategy="$arg"
        fi
    done

    validate_amount "$amount"
    local amount_wei=$(ether_to_wei "$amount")

    if [ "$count" -gt 1 ]; then
        print_header "Creating $count YieldVaults with $amount Native FLOW each"
    else
        print_header "Creating YieldVault with $amount Native FLOW"
    fi
    echo "Vault:    $vault"
    echo "Strategy: $strategy"
    echo ""

    for ((i = 1; i <= count; i++)); do
        if [ "$count" -gt 1 ]; then
            echo -e "${YELLOW}[$i/$count]${NC} Sending transaction..."
        fi

        cast send "$CONTRACT" "createYieldVault(address,uint256,string,string)" \
            "$NATIVE_FLOW" \
            "$amount_wei" \
            "$vault" \
            "$strategy" \
            --value "$amount_wei" \
            --private-key "$PRIVATE_KEY" \
            --rpc-url "$RPC_URL" \
            --gas-limit 1000000

        if [ "$count" -gt 1 ]; then
            print_success "Transaction $i/$count sent"
        else
            print_success "Transaction sent"
        fi
    done

    if [ "$count" -gt 1 ]; then
        echo ""
        print_success "All $count transactions sent"
    fi
}

create_yieldvault_wflow() {
    local amount=$1
    shift

    # Parse remaining arguments, looking for multiplier (x100) pattern
    local vault="$DEFAULT_VAULT"
    local strategy="$DEFAULT_STRATEGY"
    local count=1

    for arg in "$@"; do
        if [[ "$arg" =~ ^x([0-9]+)$ ]]; then
            count="${BASH_REMATCH[1]}"
        elif [ "$vault" = "$DEFAULT_VAULT" ] && [ -n "$arg" ]; then
            vault="$arg"
        elif [ "$strategy" = "$DEFAULT_STRATEGY" ] && [ -n "$arg" ]; then
            strategy="$arg"
        fi
    done

    validate_amount "$amount"
    local amount_wei=$(ether_to_wei "$amount")

    # Calculate total amount needed for approval
    local total_wei=$(echo "$amount_wei * $count" | bc)

    if [ "$count" -gt 1 ]; then
        print_header "Creating $count YieldVaults with $amount WFLOW each"
    else
        print_header "Creating YieldVault with $amount WFLOW"
    fi
    echo "Vault:    $vault"
    echo "Strategy: $strategy"
    echo ""

    # Approve total WFLOW upfront
    echo "Approving WFLOW (total: $(wei_to_ether $total_wei) WFLOW)..."
    cast send "$WFLOW" "approve(address,uint256)" \
        "$CONTRACT" \
        "$total_wei" \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$RPC_URL" > /dev/null

    print_success "WFLOW approved"

    for ((i = 1; i <= count; i++)); do
        if [ "$count" -gt 1 ]; then
            echo -e "${YELLOW}[$i/$count]${NC} Creating YieldVault..."
        else
            echo "Creating YieldVault..."
        fi

        cast send "$CONTRACT" "createYieldVault(address,uint256,string,string)" \
            "$WFLOW" \
            "$amount_wei" \
            "$vault" \
            "$strategy" \
            --private-key "$PRIVATE_KEY" \
            --rpc-url "$RPC_URL"

        if [ "$count" -gt 1 ]; then
            print_success "Transaction $i/$count sent"
        else
            print_success "Transaction sent"
        fi
    done

    if [ "$count" -gt 1 ]; then
        echo ""
        print_success "All $count transactions sent"
    fi
}

claim_refund() {
    local token_address="${1:-$NATIVE_FLOW}"
    print_header "Claiming Refund"
    echo "Token:   $token_address"
    echo ""

    cast send "$CONTRACT" "claimRefund(address)" \
        "$token_address" \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$RPC_URL"

    print_success "Refund claimed"
}

refund_check() {
    local amount=$1
    local vault="${2:-InvalidVault}"
    local strategy="${3:-InvalidStrategy}"

    if [ -z "$PRIVATE_KEY" ]; then
        print_error "PRIVATE_KEY is required"
        exit 1
    fi

    if [ -z "$USER" ]; then
        print_error "Unable to derive USER from PRIVATE_KEY"
        exit 1
    fi

    if [ -z "$amount" ]; then
        print_error "Amount required"
        exit 1
    fi

    validate_amount "$amount"
    local amount_wei=$(ether_to_wei "$amount")

    print_header "Refund Check (forced failure)"
    echo "Amount:   $amount FLOW"
    echo "Vault:    $vault"
    echo "Strategy: $strategy"
    echo ""

    local tx_out
    tx_out=$(cast send "$CONTRACT" "createYieldVault(address,uint256,string,string)" \
        "$NATIVE_FLOW" \
        "$amount_wei" \
        "$vault" \
        "$strategy" \
        --value "$amount_wei" \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$RPC_URL")

    local tx_hash
    tx_hash=$(extract_tx_hash "$tx_out")
    if [ -z "$tx_hash" ]; then
        print_error "Could not parse transaction hash from send output."
        echo "$tx_out"
        exit 1
    fi
    print_success "Transaction sent: $tx_hash"

    local request_id
    request_id=$(extract_request_id "$tx_hash")
    if [ -z "$request_id" ]; then
        print_error "Could not extract requestId from receipt."
        exit 1
    fi
    print_success "Request ID: $request_id"

    wait_for_request_status "$request_id" 3 "$REFUND_CHECK_MAX_ATTEMPTS" "$REFUND_CHECK_DELAY_SECONDS"

    get_user_claimable_refund "$USER" "$NATIVE_FLOW"
    claim_refund "$NATIVE_FLOW"
    check_evm_state
}

# =============================================================================
# Query Functions
# =============================================================================

get_request() {
    local request_id=$1
    print_header "Request $request_id Details"

    local result=$(cast call "$CONTRACT" "getRequest(uint256)((uint256,address,uint8,uint8,address,uint256,uint64,uint256,string,string,string))" "$request_id" --rpc-url "$RPC_URL")

    echo "$result"

    # Parse status (4th field in the tuple: id, user, requestType, status, ...)
    # Format: (id, address, type, status, token, amount, vaultId, timestamp, msg, vault, strategy)
    local status=$(echo "$result" | sed 's/[()]//g' | cut -d',' -f4 | tr -d ' ')
    case $status in
        0) echo -e "\nStatus: ${YELLOW}PENDING${NC}" ;;
        1) echo -e "\nStatus: ${BLUE}PROCESSING${NC}" ;;
        2) echo -e "\nStatus: ${GREEN}COMPLETED${NC}" ;;
        3) echo -e "\nStatus: ${RED}FAILED${NC}" ;;
    esac
}

get_yieldvault_balance() {
    local yieldvault_id=$1
    print_header "YieldVault $yieldvault_id Balance"

    cd "$PROJECT_DIR"
    flow scripts execute cadence/scripts/get_yieldvault_balance.cdc "$CADENCE_CONTRACT" "$yieldvault_id" --network testnet
}

get_user_yieldvaults() {
    print_header "User's YieldVaults"

    cd "$PROJECT_DIR"
    local yieldvaults=$(flow scripts execute cadence/scripts/check_user_yieldvaults.cdc "$USER" --network testnet)
    echo "$yieldvaults"

    # Extract IDs and show balances (macOS compatible)
    # Expected format from check_user_yieldvaults.cdc: [1, 2, 3] or similar array notation
    # This extracts all numbers from the output, treating commas as separators
    echo -e "\n${YELLOW}YieldVault Balances:${NC}"
    local ids=$(echo "$yieldvaults" | sed 's/[^0-9,]//g' | tr ',' '\n' | grep -v '^$')
    for id in $ids; do
        local balance=$(flow scripts execute cadence/scripts/get_yieldvault_balance.cdc "$CADENCE_CONTRACT" "$id" --network testnet 2>/dev/null | grep "Result:" | cut -d' ' -f2)
        echo "  YieldVault $id: $balance FLOW"
    done
}

# =============================================================================
# Admin Query Functions (direct EVM calls via cast - read-only)
# =============================================================================

get_evm_config() {
    print_header "EVM Contract Config"

    echo -e "${YELLOW}Contract: $CONTRACT${NC}"
    echo ""

    local coa=$(cast call "$CONTRACT" "authorizedCOA()(address)" --rpc-url "$RPC_URL")
    local allowlist=$(cast call "$CONTRACT" "allowlistEnabled()(bool)" --rpc-url "$RPC_URL")
    local blocklist=$(cast call "$CONTRACT" "blocklistEnabled()(bool)" --rpc-url "$RPC_URL")
    local max_requests=$(cast call "$CONTRACT" "maxPendingRequestsPerUser()(uint256)" --rpc-url "$RPC_URL")
    local pending_count=$(cast call "$CONTRACT" "getPendingRequestCount()(uint256)" --rpc-url "$RPC_URL")

    echo "Authorized COA:              $coa"
    echo "Allowlist Enabled:           $allowlist"
    echo "Blocklist Enabled:           $blocklist"
    echo "Max Pending Requests/User:   $max_requests"
    echo "Total Pending Requests:      $pending_count"
}

get_allowlist_status() {
    local address_to_check="${1:-}"
    print_header "Allowlist Status"

    local enabled=$(cast call "$CONTRACT" "allowlistEnabled()(bool)" --rpc-url "$RPC_URL")
    echo "Allowlist Enabled: $enabled"

    if [ -n "$address_to_check" ]; then
        local is_listed=$(cast call "$CONTRACT" "allowlisted(address)(bool)" "$address_to_check" --rpc-url "$RPC_URL")
        echo "Address $address_to_check: $is_listed"
    fi
}

get_blocklist_status() {
    local address_to_check="${1:-}"
    print_header "Blocklist Status"

    local enabled=$(cast call "$CONTRACT" "blocklistEnabled()(bool)" --rpc-url "$RPC_URL")
    echo "Blocklist Enabled: $enabled"

    if [ -n "$address_to_check" ]; then
        local is_listed=$(cast call "$CONTRACT" "blocklisted(address)(bool)" "$address_to_check" --rpc-url "$RPC_URL")
        echo "Address $address_to_check: $is_listed"
    fi
}

get_token_config() {
    local token_address=$1
    print_header "Token Config for $token_address"

    # allowedTokens returns (bool isSupported, uint256 minimumBalance, bool isNative)
    local result=$(cast call "$CONTRACT" "allowedTokens(address)(bool,uint256,bool)" "$token_address" --rpc-url "$RPC_URL")
    local is_supported=$(echo "$result" | sed -n '1p')
    local min_balance_raw=$(echo "$result" | sed -n '2p')
    local is_native=$(echo "$result" | sed -n '3p')
    local min_balance_wei=$(echo "$min_balance_raw" | awk '{print $1}')

    echo "Is Supported:    $is_supported"
    echo "Min Balance:     $(wei_to_ether $min_balance_wei) ($min_balance_wei wei)"
    echo "Is Native:       $is_native"
}

get_user_pending_balance() {
    local user_address=$1
    local token_address=$2
    print_header "User Pending Balance"

    local balance_wei=$(cast call "$CONTRACT" "getUserPendingBalance(address,address)(uint256)" "$user_address" "$token_address" --rpc-url "$RPC_URL")

    echo "User:    $user_address"
    echo "Token:   $token_address"
    echo "Balance: $(wei_to_ether $balance_wei) ($balance_wei wei)"
}

get_user_pending_request_count() {
    local user_address=$1
    print_header "User Pending Request Count"

    local count=$(cast call "$CONTRACT" "getUserPendingRequestCount(address)(uint256)" "$user_address" --rpc-url "$RPC_URL")

    echo "User:  $user_address"
    echo "Count: $count"
}

get_user_claimable_refund() {
    local user_address=$1
    local token_address=$2
    print_header "User Claimable Refund"

    local amount_wei=$(cast call "$CONTRACT" "getClaimableRefund(address,address)(uint256)" "$user_address" "$token_address" --rpc-url "$RPC_URL")

    echo "User:    $user_address"
    echo "Token:   $token_address"
    echo "Amount:  $(wei_to_ether $amount_wei) ($amount_wei wei)"
}

# =============================================================================
# Admin Transaction Functions (Cadence transactions calling EVM)
# =============================================================================

admin_set_allowlist() {
    local enabled=$1
    print_header "Setting Allowlist Enabled: $enabled"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/set_allowlist_enabled.cdc "$enabled" --network testnet --signer testnet-account
    print_success "Allowlist enabled set to $enabled"
}

admin_set_blocklist() {
    local enabled=$1
    print_header "Setting Blocklist Enabled: $enabled"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/set_blocklist_enabled.cdc "$enabled" --network testnet --signer testnet-account
    print_success "Blocklist enabled set to $enabled"
}

# Helper to format shell arguments as a Cadence array of strings
# e.g., "0x123" "0x456" -> ["0x123", "0x456"]
format_cadence_array() {
    local formatted=""
    for arg in "$@"; do
        if [ -n "$formatted" ]; then
            formatted+=", "
        fi
        formatted+="\"$arg\""
    done
    echo "[$formatted]"
}

admin_add_to_allowlist() {
    shift  # Remove command name
    local addresses=$(format_cadence_array "$@")
    print_header "Adding to Allowlist: $addresses"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/batch_add_to_allowlist.cdc "$addresses" --network testnet --signer testnet-account
    print_success "Addresses added to allowlist"
}

admin_remove_from_allowlist() {
    shift  # Remove command name
    local addresses=$(format_cadence_array "$@")
    print_header "Removing from Allowlist: $addresses"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/batch_remove_from_allowlist.cdc "$addresses" --network testnet --signer testnet-account
    print_success "Addresses removed from allowlist"
}

admin_add_to_blocklist() {
    shift  # Remove command name
    local addresses=$(format_cadence_array "$@")
    print_header "Adding to Blocklist: $addresses"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/batch_add_to_blocklist.cdc "$addresses" --network testnet --signer testnet-account
    print_success "Addresses added to blocklist"
}

admin_remove_from_blocklist() {
    shift  # Remove command name
    local addresses=$(format_cadence_array "$@")
    print_header "Removing from Blocklist: $addresses"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/batch_remove_from_blocklist.cdc "$addresses" --network testnet --signer testnet-account
    print_success "Addresses removed from blocklist"
}

admin_set_token_config() {
    local token=$1
    local supported=$2
    local min_balance=$3
    local is_native=$4
    print_header "Setting Token Config: $token"
    echo "Supported: $supported, MinBalance: $min_balance, IsNative: $is_native"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/set_token_config.cdc "$token" "$supported" "$min_balance" "$is_native" --network testnet --signer testnet-account
    print_success "Token config updated"
}

admin_set_max_pending_requests() {
    local max_requests=$1
    print_header "Setting Max Pending Requests Per User: $max_requests"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/set_max_pending_requests_per_user.cdc "$max_requests" --network testnet --signer testnet-account
    print_success "Max pending requests updated to $max_requests"
}

admin_drop_requests() {
    local count=$1
    print_header "Dropping $count Requests"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/drop_requests.cdc "$count" --network testnet --signer testnet-account
    print_success "$count requests dropped"
}

admin_cancel_request() {
    local request_id=$1
    print_header "Cancelling Request $request_id"

    cd "$PROJECT_DIR"
    flow transactions send cadence/transactions/admin/cancel_request.cdc "$request_id" --network testnet --signer testnet-account
    print_success "Request $request_id cancelled"
}

# =============================================================================
# Main
# =============================================================================

show_help() {
    echo "Testnet E2E Testing Script for FlowYieldVaultsEVM"
    echo ""
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "STATE COMMANDS:"
    echo "  state                              Check full state (EVM + Cadence)"
    echo "  evm-state                          Check EVM state only"
    echo "  cadence-state                      Check Cadence state only"
    echo ""
    echo "USER COMMANDS:"
    echo "  create-flow <amount> [vault] [strategy] [xN]"
    echo "                                     Create YieldVault with Native FLOW"
    echo "                                     Use xN to create N requests (e.g., x100)"
    echo "  create-wflow <amount> [vault] [strategy] [xN]"
    echo "                                     Create YieldVault with WFLOW"
    echo "                                     Use xN to create N requests (e.g., x100)"
    echo "  refund-check <amount> [vault] [strategy]"
    echo "                                     Force failure, then claim refund (defaults: InvalidVault/InvalidStrategy)"
    echo "  claim-refund [token]"
    echo "                                     Claim refund for token (default: NATIVE_FLOW)"
    echo "  request <id>                       Get request details"
    echo "  yieldvault <id>                    Get YieldVault balance"
    echo "  user-yieldvaults                   List user's YieldVaults with balances"
    echo ""
    echo "ADMIN QUERY COMMANDS (read-only):"
    echo "  config                             Get EVM contract config via Cadence"
    echo "  allowlist-status [address]         Check allowlist status (optional: check if address is listed)"
    echo "  blocklist-status [address]         Check blocklist status (optional: check if address is listed)"
    echo "  token-config <token>               Get token config (use $NATIVE_FLOW or $WFLOW)"
    echo "  pending-balance <user> <token>     Get user's pending balance for a token"
    echo "  pending-count <user>               Get user's pending request count"
    echo "  claimable-refund <user> <token>    Get user's claimable refund for a token"
    echo ""
    echo "ADMIN TRANSACTION COMMANDS (require testnet-account signer):"
    echo "  set-allowlist <true|false>         Enable/disable allowlist"
    echo "  set-blocklist <true|false>         Enable/disable blocklist"
    echo "  add-allowlist <addr1> [addr2...]   Add addresses to allowlist"
    echo "  remove-allowlist <addr1> [addr2...] Remove addresses from allowlist"
    echo "  add-blocklist <addr1> [addr2...]   Add addresses to blocklist"
    echo "  remove-blocklist <addr1> [addr2...] Remove addresses from blocklist"
    echo "  set-token <token> <supported> <minBal> <isNative>"
    echo "                                     Configure token (e.g., set-token 0x... true 1000000000000000000 false)"
    echo "  set-max-requests <count>           Set max pending requests per user"
    echo "  drop-requests <count>              Drop N oldest pending requests"
    echo "  cancel-request <id>                Cancel a specific request"
    echo ""
    echo "DEFAULT PARAMETERS:"
    echo "  Vault:       $DEFAULT_VAULT"
    echo "  Strategy:    $DEFAULT_STRATEGY"
    echo "  NATIVE_FLOW: $NATIVE_FLOW"
    echo "  WFLOW:       $WFLOW"
    echo "  CONTRACT:    $CONTRACT"
    echo "  CADENCE:     $CADENCE_CONTRACT"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 state"
    echo "  $0 create-flow 1.2"
    echo "  $0 create-flow 1.2 x100                    # Create 100 requests"
    echo "  $0 create-flow 1.5 InvalidVault InvalidStrategy"
    echo "  $0 create-wflow 1.0 x50                    # Create 50 WFLOW requests"
    echo "  $0 refund-check 0.1"
    echo "  $0 request 10"
    echo ""
    echo "  # Admin queries"
    echo "  $0 config"
    echo "  $0 allowlist-status"
    echo "  $0 allowlist-status 0x40EdeF9427E466aF2E573186338b9B115b5671c8"
    echo "  $0 token-config 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF"
    echo ""
    echo "  # Admin transactions"
    echo "  $0 set-allowlist true"
    echo "  $0 add-allowlist 0x1234... 0x5678..."
    echo "  $0 set-max-requests 10"
    echo "  $0 cancel-request 15"
}

case "$1" in
    # State commands
    state)
        check_full_state
        ;;
    evm-state)
        check_evm_state
        ;;
    cadence-state)
        check_cadence_state
        ;;

    # User commands
    create-flow)
        if [ -z "$2" ]; then
            print_error "Amount required"
            exit 1
        fi
        create_yieldvault_flow "$2" "$3" "$4" "$5"
        ;;
    create-wflow)
        if [ -z "$2" ]; then
            print_error "Amount required"
            exit 1
        fi
        create_yieldvault_wflow "$2" "$3" "$4" "$5"
        ;;
    refund-check)
        refund_check "$2" "$3" "$4"
        ;;
    claim-refund)
        claim_refund "$2"
        ;;
    request)
        if [ -z "$2" ]; then
            print_error "Request ID required"
            exit 1
        fi
        get_request "$2"
        ;;
    yieldvault)
        if [ -z "$2" ]; then
            print_error "YieldVault ID required"
            exit 1
        fi
        get_yieldvault_balance "$2"
        ;;
    user-yieldvaults)
        get_user_yieldvaults
        ;;

    # Admin query commands
    config)
        get_evm_config
        ;;
    allowlist-status)
        get_allowlist_status "$2"
        ;;
    blocklist-status)
        get_blocklist_status "$2"
        ;;
    token-config)
        if [ -z "$2" ]; then
            print_error "Token address required"
            exit 1
        fi
        get_token_config "$2"
        ;;
    pending-balance)
        if [ -z "$2" ] || [ -z "$3" ]; then
            print_error "User address and token address required"
            exit 1
        fi
        get_user_pending_balance "$2" "$3"
        ;;
    pending-count)
        if [ -z "$2" ]; then
            print_error "User address required"
            exit 1
        fi
        get_user_pending_request_count "$2"
        ;;
    claimable-refund)
        if [ -z "$2" ] || [ -z "$3" ]; then
            print_error "User address and token address required"
            exit 1
        fi
        get_user_claimable_refund "$2" "$3"
        ;;

    # Admin transaction commands
    set-allowlist)
        if [ -z "$2" ]; then
            print_error "Value required (true/false)"
            exit 1
        fi
        admin_set_allowlist "$2"
        ;;
    set-blocklist)
        if [ -z "$2" ]; then
            print_error "Value required (true/false)"
            exit 1
        fi
        admin_set_blocklist "$2"
        ;;
    add-allowlist)
        if [ -z "$2" ]; then
            print_error "At least one address required"
            exit 1
        fi
        admin_add_to_allowlist "$@"
        ;;
    remove-allowlist)
        if [ -z "$2" ]; then
            print_error "At least one address required"
            exit 1
        fi
        admin_remove_from_allowlist "$@"
        ;;
    add-blocklist)
        if [ -z "$2" ]; then
            print_error "At least one address required"
            exit 1
        fi
        admin_add_to_blocklist "$@"
        ;;
    remove-blocklist)
        if [ -z "$2" ]; then
            print_error "At least one address required"
            exit 1
        fi
        admin_remove_from_blocklist "$@"
        ;;
    set-token)
        if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ]; then
            print_error "All parameters required: <token> <supported> <minBalance> <isNative>"
            exit 1
        fi
        admin_set_token_config "$2" "$3" "$4" "$5"
        ;;
    set-max-requests)
        if [ -z "$2" ]; then
            print_error "Count required"
            exit 1
        fi
        admin_set_max_pending_requests "$2"
        ;;
    drop-requests)
        if [ -z "$2" ]; then
            print_error "Count required"
            exit 1
        fi
        admin_drop_requests "$2"
        ;;
    cancel-request)
        if [ -z "$2" ]; then
            print_error "Request ID required"
            exit 1
        fi
        admin_cancel_request "$2"
        ;;

    help|--help|-h)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
