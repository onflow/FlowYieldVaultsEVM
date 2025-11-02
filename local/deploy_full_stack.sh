#!/bin/bash

set -e  # Exit on any error

# Configuration - Edit these values as needed
DEPLOYER_EOA="0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF"
DEPLOYER_FUNDING="50.46"

USER_A_EOA="0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69"
USER_A_FUNDING="1234.12"

TIDAL_REQUESTS_CONTRACT="0x153b84F377C6C7a7D93Bd9a717E48097Ca6Cfd11"

RPC_URL="localhost:8545"

# Run all deployment steps
./local/setup_accounts.sh "$DEPLOYER_EOA" "$DEPLOYER_FUNDING" "$USER_A_EOA" "$USER_A_FUNDING"
./local/deploy_and_initialize.sh "$TIDAL_REQUESTS_CONTRACT" "$RPC_URL"

echo ""
echo "========================================="
echo "✓ Full stack deployment complete!"
echo "========================================="