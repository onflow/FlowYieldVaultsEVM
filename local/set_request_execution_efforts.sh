#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <emulator|testnet|mainnet> [value] [signer]" >&2
  echo "Example: $0 mainnet 9999 mainnet-account" >&2
}

if ! command -v flow >/dev/null 2>&1; then
  echo "Error: flow CLI is not installed or not in PATH." >&2
  exit 1
fi

NETWORK="${1:-}"
VALUE="${2:-9999}"

if [[ -z "$NETWORK" ]]; then
  usage
  exit 1
fi

case "$NETWORK" in
  emulator)
    DEFAULT_SIGNER="emulator-flow-yield-vaults"
    ;;
  testnet)
    DEFAULT_SIGNER="testnet-account"
    ;;
  mainnet)
    DEFAULT_SIGNER="mainnet-account"
    ;;
  *)
    echo "Error: unsupported network '$NETWORK'." >&2
    usage
    exit 1
    ;;
esac

SIGNER="${3:-$DEFAULT_SIGNER}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TX_PATH="$ROOT_DIR/cadence/transactions/set_execution_effort_constant.cdc"
READ_PATH="$ROOT_DIR/cadence/scripts/get_execution_effort_constants.cdc"

KEYS=(
  workerCreateYieldVaultRequestEffort
  workerDepositRequestEffort
  workerWithdrawRequestEffort
  workerCloseYieldVaultRequestEffort
)

for key in "${KEYS[@]}"; do
  echo "Setting $key -> $VALUE on $NETWORK with signer $SIGNER"
  flow transactions send "$TX_PATH" \
    "$key" \
    "$VALUE" \
    --network "$NETWORK" \
    --signer "$SIGNER" \
    --compute-limit 9999
done

echo
echo "Current execution effort constants:"
flow scripts execute "$READ_PATH" --network "$NETWORK"
