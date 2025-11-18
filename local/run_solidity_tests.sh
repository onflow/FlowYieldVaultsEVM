#!/usr/bin/env fish

# Run all Solidity tests using Foundry
echo "Running Solidity tests..."
echo ""

# Navigate to project root
cd (dirname (status -f))/..

cd solidity

if forge test
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
end
