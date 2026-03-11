#!/bin/bash

# Mainnet part 0: deploy the EVM contract from an EVM private key,
# using a placeholder COA address that can be updated later via setAuthorizedCOA.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env.mainnet.example}"
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

MAINNET_RPC_URL="${MAINNET_RPC_URL:-https://mainnet.evm.nodes.onflow.org}"
FAKE_COA_ADDRESS="${FAKE_COA_ADDRESS:-0x6fC23Ad2a0A2152C9b10454a9F50CDc9637423e2}"
CADENCE_DEPLOYER_ADDRESS="${CADENCE_DEPLOYER_ADDRESS:-0xa7d9a1bece1378a3}"
NATIVE_FLOW_ADDRESS="${NATIVE_FLOW_ADDRESS:-0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF}"
WFLOW_ADDRESS="${WFLOW_ADDRESS:-0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e}"
WETH_ADDRESS="${WETH_ADDRESS:-0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590}"
WBTC_ADDRESS="${WBTC_ADDRESS:-0x717DAE2BaF7656BE9a9B01deE31d571a9d4c9579}"
PYUSD0_ADDRESS="${PYUSD0_ADDRESS:-0x99aF3EeA856556646C98c8B9b2548Fe815240750}"
FLOW_MIN_BALANCE_WEI="${FLOW_MIN_BALANCE_WEI:-17707263519495697135}"
WFLOW_MIN_BALANCE_WEI="${WFLOW_MIN_BALANCE_WEI:-17707263519495697135}"
WETH_MIN_BALANCE_WEI="${WETH_MIN_BALANCE_WEI:-491521258294421}"
WBTC_MIN_BALANCE_WEI="${WBTC_MIN_BALANCE_WEI:-1430}"
PYUSD0_MIN_BALANCE_WEI="${PYUSD0_MIN_BALANCE_WEI:-1000000}"
DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-${PRIVATE_KEY:-}}"

if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
    echo "❌ Error: DEPLOYER_PRIVATE_KEY or PRIVATE_KEY must be set in $ENV_FILE"
    exit 1
fi

if [[ "$DEPLOYER_PRIVATE_KEY" != 0x* && "$DEPLOYER_PRIVATE_KEY" != 0X* ]]; then
    DEPLOYER_PRIVATE_KEY="0x$DEPLOYER_PRIVATE_KEY"
fi

if [[ "$FAKE_COA_ADDRESS" != 0x* && "$FAKE_COA_ADDRESS" != 0X* ]]; then
    FAKE_COA_ADDRESS="0x$FAKE_COA_ADDRESS"
fi

if [[ "$CADENCE_DEPLOYER_ADDRESS" != 0x* && "$CADENCE_DEPLOYER_ADDRESS" != 0X* ]]; then
    CADENCE_DEPLOYER_ADDRESS="0x$CADENCE_DEPLOYER_ADDRESS"
fi

export DEPLOYER_PRIVATE_KEY
export COA_ADDRESS="$FAKE_COA_ADDRESS"
export WFLOW_ADDRESS

set_token_config() {
    local token_address="$1"
    local is_supported="$2"
    local minimum_balance="$3"
    local is_native="$4"
    local label="$5"

    echo "   - Configuring $label"
    cast send \
      --legacy \
      --rpc-url "$MAINNET_RPC_URL" \
      --private-key "$DEPLOYER_PRIVATE_KEY" \
      "$DEPLOYED_ADDRESS" \
      'setTokenConfig(address,bool,uint256,bool)' \
      "$token_address" \
      "$is_supported" \
      "$minimum_balance" \
      "$is_native"
}

echo "=========================================="
echo "🚀 Mainnet Part 0: EVM Deploy"
echo "=========================================="
echo "RPC URL:            $MAINNET_RPC_URL"
echo "Placeholder COA:    $FAKE_COA_ADDRESS"
echo "Cadence deployer:   $CADENCE_DEPLOYER_ADDRESS"
echo "Verification:       skipped"
echo ""

DEPLOY_OUTPUT=$(forge script ./solidity/script/DeployFlowYieldVaultsRequests.s.sol:DeployFlowYieldVaultsRequests \
  --root ./solidity \
  --rpc-url "$MAINNET_RPC_URL" \
  --broadcast \
  --legacy 2>&1)

echo "$DEPLOY_OUTPUT"

DEPLOYED_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "FlowYieldVaultsRequests deployed at:" | sed 's/.*: //')
if [ -z "$DEPLOYED_ADDRESS" ]; then
    echo "❌ Failed to extract deployed contract address from forge output"
    exit 1
fi

echo "$DEPLOYED_ADDRESS" > "$PROJECT_ROOT/local/.mainnet_evm_contract_address"

echo ""
echo "🔧 Configuring supported tokens and minimum balances..."
set_token_config "$NATIVE_FLOW_ADDRESS" true "$FLOW_MIN_BALANCE_WEI" true "native FLOW"
set_token_config "$WFLOW_ADDRESS" true "$WFLOW_MIN_BALANCE_WEI" false "WFLOW"
set_token_config "$WETH_ADDRESS" true "$WETH_MIN_BALANCE_WEI" false "WETH"
set_token_config "$WBTC_ADDRESS" true "$WBTC_MIN_BALANCE_WEI" false "WBTC"
set_token_config "$PYUSD0_ADDRESS" true "$PYUSD0_MIN_BALANCE_WEI" false "PYUSD0"

"$PROJECT_ROOT/scripts/export-artifacts.sh" \
    --network mainnet \
    --evm-address "$DEPLOYED_ADDRESS" \
    --cadence-address "$CADENCE_DEPLOYER_ADDRESS"

echo ""
echo "✅ Mainnet EVM contract deployed"
echo ""
echo "Contract: $DEPLOYED_ADDRESS"
echo "Saved to: $PROJECT_ROOT/local/.mainnet_evm_contract_address"
echo ""
echo "Token minimums configured:"
echo "  native FLOW: $FLOW_MIN_BALANCE_WEI"
echo "  WFLOW:       $WFLOW_MIN_BALANCE_WEI"
echo "  WETH:        $WETH_MIN_BALANCE_WEI"
echo "  WBTC:        $WBTC_MIN_BALANCE_WEI"
echo "  PYUSD0:      $PYUSD0_MIN_BALANCE_WEI"
echo ""
echo "Next required steps:"
echo "  1. Run: $PROJECT_ROOT/local/mainnet_cadence_part_1_prep.sh"
echo "  2. From the EVM owner wallet, call setAuthorizedCOA(realCoaAddress)."
echo "  3. Run: $PROJECT_ROOT/local/mainnet_cadence_part_2_activate.sh"
echo ""
echo "Warning: do not route production traffic to this contract before authorizedCOA is updated."
