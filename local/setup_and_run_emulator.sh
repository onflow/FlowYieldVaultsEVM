#!/bin/bash

# Define addresses and ports as variables
COA_ADDRESS="0xf8d6e0586b0a20c7"
COA_KEY="b1a77d1b931e602dda3d70e6dcddbd8692b55940cc33a46c4e264b1d7415dd4f"
COINBASE_EOA="0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
DEPLOYER_EOA="0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF"
USER_A_EOA="0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69"
TIDAL_REQUESTS_CONTRACT="0x153b84F377C6C7a7D93Bd9a717E48097Ca6Cfd11"
EMULATOR_PORT=8080
RPC_PORT=8545

# Start Flow emulator in the background
flow emulator &

# Wait for emulator port to be available
echo "Waiting for port $EMULATOR_PORT to be ready..."
while ! nc -z localhost $EMULATOR_PORT; do
  sleep 1
done

echo "Port $EMULATOR_PORT is ready!"

# Clean the db directory
echo "Cleaning ./db directory..."
if [ -d "./db" ]; then
  rm -rf ./db/*
  echo "Database directory cleaned."
else
  echo "Database directory does not exist, creating it..."
  mkdir -p ./db
fi

# Start Flow EVM gateway
echo "Starting Flow EVM gateway on RPC port $RPC_PORT..."
flow evm gateway --coa-address $COA_ADDRESS \
                 --coa-key $COA_KEY \
                 --coa-resource-create \
                 --coinbase $COINBASE_EOA \
                 --rpc-port $RPC_PORT \
                 --evm-network-id preview &

# Display account information
echo ""
echo "=== Account Information ==="
echo "coinbase (EOA): $COINBASE_EOA"
echo "deployer (EOA): $DEPLOYER_EOA"
echo "userA (EOA): $USER_A_EOA"
echo "TidalRequests contract: $TIDAL_REQUESTS_CONTRACT"
echo "RPC Port: $RPC_PORT"
echo "=========================="

# Run the tidal-sc setup script in its directory
echo ""
echo "Running tidal-sc setup script..."
cd ./lib/tidal-sc
./local/setup_emulator.sh
cd ../..

echo ""
echo "Setup complete! Now using root flow.json for future operations."