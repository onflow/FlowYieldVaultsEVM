# FlowYieldVaults EVM Integration - Testing Documentation

**Status**: Not run in this environment. Use the commands below to verify.
**Last Updated**: 2026-01-05

## Overview

Comprehensive test suite for the Flow YieldVaults EVM Integration, covering both Solidity and Cadence components. Tests validate request lifecycle, access control, error handling, allowlist/blocklist functionality, and cross-VM integration. Local E2E scripts under `local/` exercise full emulator flows; `local/testnet-e2e.sh` provides manual testnet checks.

## Test Summary

| Component | Tests | Notes |
|-----------|-------|-------|
| **Solidity (Foundry)** | 37 | Unit tests in `solidity/test/` |
| **Cadence (Flow CLI)** | 22 | Unit/integration tests in `cadence/tests/` |
| **Local E2E (Emulator)** | Scripted | `./local/run_e2e_tests.sh` |
| **Local Admin E2E (Emulator)** | Scripted | `./local/run_admin_e2e_tests.sh` |
| **Testnet CLI (Manual)** | N/A | `./local/testnet-e2e.sh --help` |

E2E scripts run scenario-based checks rather than a fixed test count; use the script output to verify pass/fail.

## Test Organization

### Solidity Tests (EVM Side)

```
solidity/test/
└── FlowYieldVaultsRequests.t.sol        # 37 tests - Complete EVM contract testing
```

**Test Categories**:
- User request creation (CREATE/DEPOSIT/WITHDRAW/CLOSE) - 8 tests
- COA operations & authorization - 7 tests
- Request lifecycle & cancellation - 3 tests
- Events & state management - 6 tests
- Pagination & queries - 3 tests
- Multi-user isolation - 2 tests
- Admin functions - 5 tests
- **Allowlist functionality** - 3 tests

### Cadence Tests (Flow Side)

```
cadence/tests/
├── evm_bridge_lifecycle_test.cdc   # 8 tests - Request lifecycle
├── access_control_test.cdc         # 7 tests - Security & admin controls
├── error_handling_test.cdc         # 4 tests - Edge cases & errors
├── validation_test.cdc             # 3 tests - CREATE_YIELDVAULT parameter validation
├── test_helpers.cdc                # Shared test utilities
└── transactions/                   # Test-specific transactions
    └── setup_worker_for_test.cdc
```

### Local E2E Scripts (Emulator + Testnet Helpers)

```
local/
├── setup_and_run_emulator.sh   # Bootstraps emulator, dependencies, gateway, and local FlowYieldVaults
├── deploy_full_stack.sh        # Funds local EOAs, deploys EVM contract, configures Cadence Worker
├── run_e2e_tests.sh            # End-to-end user flows (create/deposit/withdraw/close/cancel)
├── run_admin_e2e_tests.sh      # End-to-end admin flows (allowlist/blocklist/token config/max requests)
├── run_cadence_tests.sh         # Wrapper for flow test (cleans db/imports)
├── run_solidity_tests.sh        # Wrapper for forge test
├── testnet-e2e.sh              # Testnet CLI for state checks + user/admin actions
└── deploy_and_verify.sh         # Testnet deploy/verify flow using COA + KMS
```

---

## Running Tests

### Solidity Tests (Foundry)

```bash
# Run all Solidity tests (37 tests)
./local/run_solidity_tests.sh

# Or run directly
cd solidity && forge test

# Run with verbosity
cd solidity && forge test -vvv

# Run specific test
cd solidity && forge test --match-test test_CreateYieldVault

# Run gas report
cd solidity && forge test --gas-report
```

### Cadence Tests (Flow CLI)

```bash
# Run via wrapper (cleans ./db and ./imports first)
./local/run_cadence_tests.sh

# Or run individual test files
# Run individual test files
flow test cadence/tests/evm_bridge_lifecycle_test.cdc  # 8 tests
flow test cadence/tests/access_control_test.cdc        # 7 tests
flow test cadence/tests/error_handling_test.cdc        # 4 tests
flow test cadence/tests/validation_test.cdc            # 3 tests

# Run all Cadence tests
for test in cadence/tests/*_test.cdc; do
    flow test "$test"
done
```

### Local E2E (Emulator)

```bash
# Full local sequence
./local/setup_and_run_emulator.sh
./local/deploy_full_stack.sh
./local/run_e2e_tests.sh
./local/run_admin_e2e_tests.sh
```

Notes:
- `./local/setup_and_run_emulator.sh` kills processes on common ports and cleans `./db`/`./imports`.
- `./local/deploy_full_stack.sh` writes the deployed EVM address to `./local/.deployed_contract_address`.
- E2E scripts read `./local/.deployed_contract_address` or `FLOW_VAULTS_REQUESTS_CONTRACT` if set.

### Testnet (Manual CLI)

```bash
./local/testnet-e2e.sh --help
PRIVATE_KEY=0xYOUR_KEY TESTNET_RPC_URL=https://testnet.evm.nodes.onflow.org \
  ./local/testnet-e2e.sh state
```

Update the hardcoded `CONTRACT` address in `./local/testnet-e2e.sh` after each new deployment.

---

## Solidity Test Coverage (37 tests)

| Category | Tests | Key Focus |
|----------|-------|-----------|
| User request creation | 8 | CREATE/DEPOSIT/WITHDRAW/CLOSE, validation, cancellation |
| COA operations | 7 | Authorized worker operations, startProcessing, completeProcessing |
| Request lifecycle | 3 | End-to-end flows, ownership validation |
| Events & state | 6 | Event emission, state tracking |
| Pagination & queries | 3 | Batch retrieval, Cadence compatibility |
| Multi-user isolation | 2 | Independent balances, no cross-user interference |
| Admin functions | 5 | SetAuthorizedCOA, ownership transfer, token config |
| Allowlist | 3 | Beta access, batch operations, error handling |

**Key Validations**:
- Request IDs increment, pending balances track escrow
- Only authorized COA can update requests/balances
- Two-phase commit (startProcessing → completeProcessing) maintains consistency
- Allowlist/blocklist enforce access control
- No double-spending or cross-user vulnerabilities

---

## Cadence Test Coverage (22 tests)

| Test File | Tests | Key Focus |
|-----------|-------|-----------|
| `evm_bridge_lifecycle_test.cdc` | 8 | Request lifecycle (CREATE → DEPOSIT → WITHDRAW → CLOSE), multi-user isolation |
| `access_control_test.cdc` | 7 | Admin controls, COA requirements, beta badge enforcement |
| `error_handling_test.cdc` | 4 | Edge cases, invalid requests, boundary conditions |
| `validation_test.cdc` | 3 | CREATE_YIELDVAULT parameter validation (strategy/vault identifiers) |

**Key Validations**:
- Request types properly structured and processed
- Admin resource required for privileged operations
- Worker creation requires COA and beta badge
- Invalid requests handled gracefully
- Boundary values tested (zero, max UInt256)

---

## Detailed Test Summary

| Component | Tests | Categories |
|-----------|-------|------------|
| **Solidity** | 37 | Request creation (8), COA ops (7), Lifecycle (3), Events (6), Pagination (3), Multi-user (2), Admin (5), Allowlist (3) |
| **Cadence** | 22 | Lifecycle (8), Access control (7), Error handling (4), Validation (3) |
| **Total** | **59** | **Unit/integration test count (E2E scripts not included)** |

---

## Test Helpers (Cadence)

---

## Test Results

### Sample Output (Historical)

The snippet below is for reference and may be stale. Re-run tests in your environment to get current results.

#### Solidity Tests (Foundry)
```
Ran 37 tests for test/FlowYieldVaultsRequests.t.sol:FlowYieldVaultsRequestsTest
[PASS] test_AcceptOwnership_RevertNotPendingOwner()
[PASS] test_Allowlist()
[PASS] test_Blocklist()
[PASS] test_BlocklistTakesPrecedence()
[PASS] test_CancelRequest_RefundsFunds()
[PASS] test_CancelRequest_RevertAlreadyCancelled()
[PASS] test_CancelRequest_RevertNotOwner()
[PASS] test_CloseYieldVault()
[PASS] test_CompleteProcessing_CloseYieldVaultRemovesOwnership()
[PASS] test_CompleteProcessing_FailureRefundsBalance()
[PASS] test_CompleteProcessing_RevertNotProcessing()
[PASS] test_CompleteProcessing_Success()
[PASS] test_CreateYieldVault()
[PASS] test_CreateYieldVault_RevertBelowMinimum()
[PASS] test_CreateYieldVault_RevertMsgValueMismatch()
[PASS] test_CreateYieldVault_RevertZeroAmount()
[PASS] test_DepositToYieldVault()
[PASS] test_DepositToYieldVault_RevertInvalidYieldVaultId()
[PASS] test_DepositToYieldVault_RevertNotOwner()
[PASS] test_DropRequests()
[PASS] test_FullCreateYieldVaultLifecycle()
[PASS] test_FullWithdrawLifecycle()
[PASS] test_GetPendingRequestsUnpacked()
[PASS] test_GetPendingRequestsUnpacked_Pagination()
[PASS] test_MaxPendingRequests_EnforcesLimit()
[PASS] test_SetAuthorizedCOA()
[PASS] test_SetAuthorizedCOA_RevertZeroAddress()
[PASS] test_SetMaxPendingRequestsPerUser()
[PASS] test_SetTokenConfig()
[PASS] test_StartProcessing_RevertNotPending()
[PASS] test_StartProcessing_RevertUnauthorized()
[PASS] test_StartProcessing_Success()
[PASS] test_TransferOwnership_NewOwnerHasAdminRights()
[PASS] test_TransferOwnership_RevertNotOwner()
[PASS] test_TransferOwnership_TwoStepProcess()
[PASS] test_UserBalancesAreSeparate()
[PASS] test_WithdrawFromYieldVault()
```

#### Cadence Tests (Flow CLI)
```
evm_bridge_lifecycle_test.cdc: 8 tests PASS
- testCreateYieldVaultFromEVMRequest
- testDepositToExistingYieldVault
- testWithdrawFromYieldVault
- testCloseYieldVaultComplete
- testRequestStatusTransitions
- testMultipleUsersIndependentYieldVaults
- testProcessResultStructure
- testVaultAndStrategyIdentifiers

access_control_test.cdc: 7 tests PASS
- testContractInitialState
- testOnlyAdminCanupdateRequestsAddress
- testOnlyAdminCanUpdateMaxRequests
- testRequestsAddressCanBeUpdated
- testWorkerCreationRequiresCOA
- testWorkerCreationRequiresBetaBadge
- testYieldVaultsByEVMAddressMapping

error_handling_test.cdc: 4 tests PASS
- testInvalidRequestType
- testZeroAmountWithdrawal
- testRequestStatusCompletedStructure
- testRequestStatusFailedStructure

validation_test.cdc: 3 tests PASS
- testCompositeTypeReturnsNilForInvalidStrategy
- testCompositeTypeReturnsNonNilForValidType
- testUnsupportedStrategyNotInSupportedList
```

**Total: 59 tests (sample output)**

---

## Testing Patterns

### Solidity (Foundry)
- Uses Forge standard library for assertions
- Helper contract exposes internal state for testing
- Event expectations with `vm.expectEmit()`
- Gas reporting available with `--gas-report`

### Cadence (Flow Testing Framework)
```cadence
access(all) fun setup() {
    deployContracts()
    // Additional setup...
}

access(all) fun testFeatureName() {
    // Test implementation
}
```

**Assertions**:
- `Test.expect(result, Test.beSucceeded())` - Transaction success
- `Test.assertEqual(expected, actual)` - Value equality
- `Test.assert(condition, message: "...")` - Boolean conditions

---

## CI/CD Integration

```yaml
- name: Run Solidity Tests
  run: cd solidity && forge test

- name: Run Cadence Tests
  run: |
    flow test cadence/tests/evm_bridge_lifecycle_test.cdc
    flow test cadence/tests/access_control_test.cdc
    flow test cadence/tests/error_handling_test.cdc
    flow test cadence/tests/validation_test.cdc
```

---

**Built with Foundry & Cadence Testing Framework**
