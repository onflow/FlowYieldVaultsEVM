#!/bin/bash

# Deploy and verify FlowVaultsRequests contract
# Run this script from the solidity/ directory

# Load environment variables from parent .env file
export $(grep -v '^#' ../.env | xargs)

echo "🚀 Deploying FlowVaultsRequests..."

# Deploy the contract
forge script script/DeployFlowVaultsRequests.s.sol:DeployFlowVaultsRequests \
    --rpc-url https://testnet.evm.nodes.onflow.org \
    --broadcast \
    -vvvv

# Extract the deployed contract address from the broadcast file
DEPLOYED_ADDRESS=$(jq -r '.transactions[0].contractAddress' broadcast/DeployFlowVaultsRequests.s.sol/545/run-latest.json)

echo ""
echo "📝 Deployed contract address: $DEPLOYED_ADDRESS"
echo ""

# Read COA address from .env file in parent directory
COA_ADDRESS=$(grep COA_ADDRESS ../.env | cut -d '=' -f2)

echo "⏳ Waiting 30 seconds for block explorer to index the deployment..."
sleep 30

echo "🔍 Verifying contract..."
echo "COA Address (constructor arg): $COA_ADDRESS"
echo ""

# Verify the contract
forge verify-contract \
  --rpc-url https://testnet.evm.nodes.onflow.org/ \
  --verifier blockscout \
  --verifier-url 'https://evm-testnet.flowscan.io/api/' \
  --constructor-args $(cast abi-encode "constructor(address)" $COA_ADDRESS) \
  --compiler-version 0.8.18 \
  $DEPLOYED_ADDRESS \
  src/FlowVaultsRequests.sol:FlowVaultsRequests

echo ""
echo "✅ Deployment and verification complete!"
echo "Contract address: $DEPLOYED_ADDRESS"
