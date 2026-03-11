#!/bin/bash

# Mainnet-only Cadence preparation flow.
# Assumptions:
# - The EVM contract is already deployed and verified.
# - Beta cap is already issued to the worker account.
# - This script should not perform any EVM-side actions yet.

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

MAINNET_EVM_CONTRACT_ADDRESS="${MAINNET_EVM_CONTRACT_ADDRESS:-0x6e8563dc44757c71a28f253cdf54410bf1ec9bd8}"
if [[ "$MAINNET_EVM_CONTRACT_ADDRESS" != 0x* && "$MAINNET_EVM_CONTRACT_ADDRESS" != 0X* ]]; then
    MAINNET_EVM_CONTRACT_ADDRESS="0x${MAINNET_EVM_CONTRACT_ADDRESS}"
fi

EVM_EXPLORER_BASE_URL="${EVM_EXPLORER_BASE_URL:-https://evm.flowscan.io}"

flow_cmd() {
    flow -f "$FLOW_CONFIG_PATH" "$@"
}

upsert_contract_alias() {
    local contract_name="$1"
    local network="$2"
    local address="$3"
    local temp_file=""

    temp_file=$(mktemp)
    jq --arg contract_name "$contract_name" \
       --arg network "$network" \
       --arg address "$address" \
       '.contracts[$contract_name].aliases[$network] = $address' \
       "$FLOW_CONFIG_PATH" > "$temp_file"
    mv "$temp_file" "$FLOW_CONFIG_PATH"
}

contract_exists_on_account() {
    local account_json="$1"
    local contract_name="$2"

    jq -e --arg contract_name "$contract_name" '
        if (.contracts | type) == "array" then
            any(.contracts[]?;
                if (type) == "object" then
                    (.name // empty) == $contract_name
                elif (type) == "string" then
                    . == $contract_name
                else
                    false
                end
            )
        elif (.contracts | type) == "object" then
            .contracts[$contract_name] != null
        else
            false
        end
    ' >/dev/null <<<"$account_json"
}

is_incompatible_update_error() {
    local output="$1"
    [[ "$output" == *"cannot deploy invalid contract"* || "$output" == *"mismatching field"* || "$output" == *"found new field"* || "$output" == *"missing event declaration"* ]]
}

deploy_or_update_cadence_contract() {
    local contract_name="$1"
    local contract_path="$2"
    local account_json=""
    local action=""
    local verb=""
    local output=""

    account_json=$(flow_cmd accounts get "$FLOW_ACCOUNT_ADDRESS" \
        --network "$FLOW_NETWORK" \
        --include contracts \
        --output json)

    if contract_exists_on_account "$account_json" "$contract_name"; then
        action="update-contract"
        verb="update"
    else
        action="add-contract"
        verb="deploy"
    fi

    echo "   - Attempting to ${verb} ${contract_name}..."
    if output=$(flow_cmd accounts "$action" "$contract_path" \
        --network "$FLOW_NETWORK" \
        --signer "$FLOW_SIGNER" 2>&1); then
        echo "$output"
        return 0
    fi

    echo "$output"

    if [[ "$output" == *"contract already exists and is the same as the contract provided for update"* ]]; then
        echo "✅ ${contract_name} already up to date on-chain"
        return 0
    fi

    if is_incompatible_update_error "$output"; then
        echo "❌ On-chain compatibility blocked ${contract_name} ${verb}. Stopping deploy."
        return 1
    fi

    echo "❌ Failed to ${verb} ${contract_name}."
    return 1
}

echo "=========================================="
echo "🚀 Mainnet Cadence Deployment Prep"
echo "=========================================="
echo "Network: mainnet"
echo "Signer:   $FLOW_SIGNER ($FLOW_ACCOUNT_ADDRESS_HEX)"
echo "EVM App:  $MAINNET_EVM_CONTRACT_ADDRESS"
echo "Mode:     Cadence only"
echo ""

# ==========================================
# Step 1: Setup COA
# ==========================================
echo "🔑 Step 1: Ensuring COA exists..."

flow_cmd transactions send "$PROJECT_ROOT/cadence/transactions/setup_coa.cdc" \
    --network "$FLOW_NETWORK" \
    --signer "$FLOW_SIGNER" \
    --compute-limit 9999

COA_ADDRESS=$(flow_cmd scripts execute "$PROJECT_ROOT/cadence/scripts/get_coa_address.cdc" "$FLOW_ACCOUNT_ADDRESS" \
    --network "$FLOW_NETWORK" \
    --output json | jq -r '.value')

if [ -z "$COA_ADDRESS" ] || [ "$COA_ADDRESS" == "null" ]; then
    echo "❌ Error: Could not get COA address"
    exit 1
fi

echo "$COA_ADDRESS" > "$PROJECT_ROOT/local/.mainnet_coa_address"

echo ""
echo "✅ COA ready at EVM address: $COA_ADDRESS"
echo "   Saved to: $PROJECT_ROOT/local/.mainnet_coa_address"
echo ""

# ==========================================
# Step 2: Deploy Cadence contracts
# ==========================================
echo "📦 Step 2: Deploying Cadence contracts..."

upsert_contract_alias "FlowYieldVaultsEVM" "$FLOW_NETWORK" "$FLOW_ACCOUNT_ADDRESS"
upsert_contract_alias "FlowYieldVaultsEVMWorkerOps" "$FLOW_NETWORK" "$FLOW_ACCOUNT_ADDRESS"

if ! deploy_or_update_cadence_contract "FlowYieldVaultsEVM" "$PROJECT_ROOT/cadence/contracts/FlowYieldVaultsEVM.cdc"; then
    exit 1
fi

if ! deploy_or_update_cadence_contract "FlowYieldVaultsEVMWorkerOps" "$PROJECT_ROOT/cadence/contracts/FlowYieldVaultsEVMWorkerOps.cdc"; then
    exit 1
fi

echo ""
echo "✅ Cadence contracts deployed"
echo ""

# ==========================================
# Step 3: Export artifacts and addresses
# ==========================================
echo "📦 Step 3: Exporting artifacts and updating contract addresses..."

"$PROJECT_ROOT/scripts/export-artifacts.sh" \
    --network "$FLOW_NETWORK" \
    --evm-address "$MAINNET_EVM_CONTRACT_ADDRESS" \
    --cadence-address "$FLOW_ACCOUNT_ADDRESS_HEX"

echo ""
echo "✅ Artifacts exported and addresses updated"
echo ""

echo "=========================================="
echo "✅ Cadence Preparation Complete"
echo "=========================================="
echo ""
echo "📋 Summary:"
echo "   COA:              $COA_ADDRESS"
echo "   EVM Contract:     $MAINNET_EVM_CONTRACT_ADDRESS"
echo "   Cadence Deployer: $FLOW_ACCOUNT_ADDRESS_HEX"
echo "   Worker Setup:     Not run"
echo "   Scheduler Init:   Not run"
echo "   WFLOW Approval:   Not run"
echo ""
echo "Next steps:"
echo "  1. From the EVM owner wallet, call setAuthorizedCOA($COA_ADDRESS)."
echo "  2. Then run: $PROJECT_ROOT/local/mainnet_cadence_part_2_activate.sh"
echo ""
echo "🔗 EVM Contract:"
echo "   $EVM_EXPLORER_BASE_URL/address/$MAINNET_EVM_CONTRACT_ADDRESS"
echo ""
