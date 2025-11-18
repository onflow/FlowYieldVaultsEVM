#!/bin/bash

# Run all Cadence tests
echo "Running Cadence tests..."
echo ""

# Navigate to project root
cd "$(dirname "$0")/.."

test_files=(
    "cadence/tests/access_control_test.cdc"
    "cadence/tests/error_handling_test.cdc"
    "cadence/tests/evm_bridge_lifecycle_test.cdc"
)

failed_tests=0
passed_tests=0

for test_file in "${test_files[@]}"; do
    echo "Running: $test_file"
    if flow test "$test_file"; then
        passed_tests=$((passed_tests + 1))
        echo "✓ PASSED: $test_file"
    else
        failed_tests=$((failed_tests + 1))
        echo "✗ FAILED: $test_file"
    fi
    echo ""
done

echo "=========================================="
echo "Test Results Summary:"
echo "Passed: $passed_tests"
echo "Failed: $failed_tests"
echo "=========================================="

if [ $failed_tests -gt 0 ]; then
    exit 1
else
    exit 0
fi
