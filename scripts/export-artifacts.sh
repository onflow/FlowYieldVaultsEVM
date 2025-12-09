#!/bin/bash
# Export ABIs and update deployment addresses

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
NETWORK=""
EVM_ADDRESS=""

usage() {
    echo "Usage: $0 [--network <testnet|mainnet>] [--evm-address <address>]"
    echo ""
    echo "Options:"
    echo "  --network      Network to update (testnet or mainnet)"
    echo "  --evm-address  EVM contract address for FlowYieldVaultsRequests"
    echo ""
    echo "Examples:"
    echo "  $0                                          # Only export ABIs"
    echo "  $0 --network testnet --evm-address 0x123   # Export ABIs and update testnet addresses"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --network)
            NETWORK="$2"
            shift 2
            ;;
        --evm-address)
            EVM_ADDRESS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Validate arguments
if [[ -n "$EVM_ADDRESS" && -z "$NETWORK" ]]; then
    echo -e "${RED}Error: --network is required when --evm-address is provided${NC}"
    usage
fi

if [[ -n "$NETWORK" && "$NETWORK" != "testnet" && "$NETWORK" != "mainnet" ]]; then
    echo -e "${RED}Error: --network must be 'testnet' or 'mainnet'${NC}"
    usage
fi

echo -e "${GREEN}Exporting contract artifacts...${NC}"

# Create directories if they don't exist
mkdir -p deployments/artifacts

# Build contracts
echo -e "${YELLOW}Building contracts...${NC}"
cd solidity && forge build && cd ..

# Extract ABI
echo -e "${YELLOW}Extracting FlowYieldVaultsRequests ABI...${NC}"
jq '.abi' solidity/out/FlowYieldVaultsRequests.sol/FlowYieldVaultsRequests.json > deployments/artifacts/FlowYieldVaultsRequests.json

echo -e "${GREEN}✓ ABI exported to deployments/artifacts/FlowYieldVaultsRequests.json${NC}"

# Update addresses if network is specified
if [[ -n "$NETWORK" ]]; then
    echo ""
    echo -e "${YELLOW}Updating addresses for ${NETWORK}...${NC}"

    ADDRESSES_FILE="deployments/contract-addresses.json"
    FLOW_JSON="flow.json"

    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq is required but not installed${NC}"
        exit 1
    fi

    # Get Cadence address from flow.json
    CADENCE_ADDRESS=$(jq -r ".contracts.FlowYieldVaultsEVM.aliases.${NETWORK} // empty" "$FLOW_JSON")

    if [[ -z "$CADENCE_ADDRESS" ]]; then
        echo -e "${RED}Error: Could not find FlowYieldVaultsEVM address for ${NETWORK} in flow.json${NC}"
        exit 1
    fi

    # Add 0x prefix if not present
    if [[ ! "$CADENCE_ADDRESS" =~ ^0x ]]; then
        CADENCE_ADDRESS="0x${CADENCE_ADDRESS}"
    fi

    echo -e "  Cadence FlowYieldVaultsEVM: ${GREEN}${CADENCE_ADDRESS}${NC} (from flow.json)"

    # Update Cadence address
    TEMP_FILE=$(mktemp)
    jq ".contracts.FlowYieldVaultsEVM.addresses.${NETWORK} = \"${CADENCE_ADDRESS}\"" "$ADDRESSES_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$ADDRESSES_FILE"

    # Update EVM address if provided
    if [[ -n "$EVM_ADDRESS" ]]; then
        # Normalize EVM address (lowercase)
        EVM_ADDRESS=$(echo "$EVM_ADDRESS" | tr '[:upper:]' '[:lower:]')

        echo -e "  EVM FlowYieldVaultsRequests: ${GREEN}${EVM_ADDRESS}${NC}"

        TEMP_FILE=$(mktemp)
        jq ".contracts.FlowYieldVaultsRequests.addresses.${NETWORK} = \"${EVM_ADDRESS}\"" "$ADDRESSES_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$ADDRESSES_FILE"
    fi

    # Update timestamp
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    TEMP_FILE=$(mktemp)
    jq ".metadata.lastUpdated = \"${TIMESTAMP}\"" "$ADDRESSES_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$ADDRESSES_FILE"

    echo -e "${GREEN}✓ Addresses updated in ${ADDRESSES_FILE}${NC}"
fi

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
echo "Exported files:"
echo "  - deployments/artifacts/FlowYieldVaultsRequests.json (ABI)"
if [[ -n "$NETWORK" ]]; then
    echo "  - deployments/contract-addresses.json (updated for ${NETWORK})"
fi
