#!/bin/bash

# Run all Solidity tests using Foundry
echo "Running Solidity tests..."
echo ""

# Navigate to project root
cd "$(dirname "$0")/.."

cd solidity

if forge test; then
    echo ""
    echo "=========================================="
    echo "✓ All Solidity tests passed"
    echo "=========================================="
    exit 0
else
    echo ""
    echo "=========================================="
    echo "✗ Some Solidity tests failed"
    echo "=========================================="
    exit 1
fi
