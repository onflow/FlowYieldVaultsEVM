#!/usr/bin/env fish

# Run all Cadence tests
echo "Running Cadence tests..."
echo ""

# Navigate to project root
cd (dirname (status -f))/..

set test_files \
    cadence/tests/access_control_test.cdc \
    cadence/tests/error_handling_test.cdc \
    cadence/tests/evm_bridge_lifecycle_test.cdc

set failed_tests 0
set passed_tests 0

for test_file in $test_files
    echo "Running: $test_file"
    if flow test $test_file
        set passed_tests (math $passed_tests + 1)
        echo "✓ PASSED: $test_file"
    else
        set failed_tests (math $failed_tests + 1)
        echo "✗ FAILED: $test_file"
    end
    echo ""
end

echo "=========================================="
echo "Test Results Summary:"
echo "Passed: $passed_tests"
echo "Failed: $failed_tests"
echo "=========================================="

if test $failed_tests -gt 0
    exit 1
else
    exit 0
end
