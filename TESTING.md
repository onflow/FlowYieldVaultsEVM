# FlowYieldVaults EVM Integration - Testing Documentation

**Status**: Last run in this environment on 2026-01-13 (Solidity: 67 passed, Cadence: 22 passed).
**Last Updated**: 2026-01-13

## Overview

Comprehensive test suite for the Flow YieldVaults EVM Integration, covering both Solidity and Cadence components. Tests validate request lifecycle, access control, error handling, allowlist/blocklist functionality, and cross-VM integration. Local E2E scripts under `local/` exercise full emulator flows; `local/testnet-e2e.sh` provides manual testnet checks.

## Test Summary

| Component | Tests | Notes |
|-----------|-------|-------|
| **Solidity (Foundry)** | 67 | Unit tests in `solidity/test/` |
| **Cadence (Flow CLI)** | 22 | Unit/integration tests in `cadence/tests/` |
| **Local E2E (Emulator)** | Scripted | `./local/run_e2e_tests.sh` |
| **Local Admin E2E (Emulator)** | Scripted | `./local/run_admin_e2e_tests.sh` |
| **Testnet CLI (Manual)** | N/A | `./local/testnet-e2e.sh --help` |

E2E scripts run scenario-based checks rather than a fixed test count; use the script output to verify pass/fail.

## Test Organization

### Solidity Tests (EVM Side)

```
solidity/test/
└── FlowYieldVaultsRequests.t.sol        # 67 tests - Complete EVM contract testing
```

**Test Categories**:
- User request lifecycle - 7 tests
- Claim refunds - 4 tests
- COA processing (startProcessing/completeProcessing) - 7 tests
- Admin functions - 6 tests
- Ownership transfer - 4 tests
- Access control (allowlist/blocklist) - 3 tests
- Validation & input checks - 8 tests
- Multi-user isolation - 1 test
- View functions & pagination - 2 tests
- Integration full lifecycle - 2 tests
- WFLOW support - 3 tests
- FIFO queue behavior - 5 tests
- Per-user pending requests view - 5 tests
- User request index tracking - 2 tests
- YieldVault index tracking - 3 tests
- Stress tests - 2 tests
- Edge cases - 3 tests

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
# Run all Solidity tests (67 tests)
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

Set `CONTRACT`/`CADENCE_CONTRACT` or update `deployments/contract-addresses.json` after each new deployment (the script loads those automatically, with a fallback to defaults).

---

## Solidity Test Coverage (67 tests)

| Category | Tests | Key Focus |
|----------|-------|-----------|
| User request lifecycle | 7 | CREATE/DEPOSIT/WITHDRAW/CLOSE, cancel |
| Claim refunds | 4 | claimRefund flow, balances, events |
| COA processing | 7 | startProcessing/completeProcessing authorization and state |
| Admin functions | 6 | COA, token config, max requests, dropRequests |
| Ownership transfer | 4 | Two-step ownership, admin rights |
| Access control | 3 | Allowlist/blocklist enforcement |
| Validation & input checks | 8 | Amounts, identifiers, yield vault IDs |
| Multi-user isolation | 1 | Independent pending balances |
| View functions & pagination | 2 | getPendingRequestsUnpacked paging |
| Integration full lifecycle | 2 | End-to-end create/withdraw |
| WFLOW support | 3 | WFLOW config, immutability, zero address |
| FIFO queue behavior | 5 | Pending queue ordering after removals |
| Per-user pending requests view | 5 | getPendingRequestsByUserUnpacked cases |
| User request index tracking | 2 | Index integrity after operations |
| YieldVault index tracking | 3 | Register/unregister, multiple vaults |
| Stress tests | 2 | Many requests/users correctness |
| Edge cases | 3 | Single request removal, failed processing, cancel middle |

**Key Validations**:
- Request IDs increment, pending balances track escrow, refunds are claimable
- Only authorized COA can start/complete processing
- Two-phase commit (startProcessing → completeProcessing) maintains consistency
- Allowlist/blocklist and admin controls enforce access
- FIFO order and per-user indexes remain consistent after removals

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
| **Solidity** | 67 | Lifecycle (7), Refunds (4), COA (7), Admin (6), Ownership (4), Access control (3), Validation (8), Views (2), Integration (2), WFLOW (3), FIFO (5), Per-user views (5), Index tracking (5), Stress (2), Edge (3), Multi-user (1) |
| **Cadence** | 22 | Lifecycle (8), Access control (7), Error handling (4), Validation (3) |
| **Total** | **89** | **Unit/integration test count (E2E scripts not included)** |

---

## Test Helpers (Cadence)

---

## Test Results

### Latest Results (2026-01-13)

- Solidity (Foundry): 67/67 passed via `./local/run_solidity_tests.sh`
- Cadence (Flow CLI): 22/22 passed via `./local/run_cadence_tests.sh`

### Sample Output (Historical)

The snippet below is for reference and may be stale. Re-run tests in your environment to get current results.

#### Solidity Tests (Foundry)
```
Ran 67 tests for test/FlowYieldVaultsRequests.t.sol:FlowYieldVaultsRequestsTest
[PASS] test_CreateYieldVault()
[PASS] test_ClaimRefund_Success()
[PASS] test_StartProcessing_Success()
[PASS] test_CompleteProcessing_Success()
[PASS] test_FIFOOrder_MaintainedAfterRemoval()
[PASS] test_GetPendingRequestsByUserUnpacked_SingleUser()
[PASS] test_WFLOWConfiguredOnDeployment()
[PASS] test_YieldVaultIndex_RegisterAndUnregister()
[PASS] test_CancelMiddleRequest_UpdatesIndexCorrectly()
[PASS] test_WithdrawFromYieldVault()
... (output truncated)
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

**Total: 89 tests (sample output)**

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
