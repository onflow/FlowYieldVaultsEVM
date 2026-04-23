# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Cursor, Copilot, and others) working in this
repository. Loaded into agent context automatically — keep it concise.

## Overview

Cross-VM bridge that lets Flow EVM users drive the Cadence-based Flow YieldVaults yield
protocol asynchronously. EVM users submit requests to a Solidity contract that escrows funds;
a Cadence worker, wired to a COA (Cadence Owned Account), processes each request and bridges
funds between VMs. The repo contains one Solidity contract, two Cadence contracts, a shared
test helper module, Foundry + `flow test` suites, and shell scripts that stitch the two VMs
together for local and testnet runs.

## Build and Test Commands

Solidity (Foundry, run from `solidity/`):
- `forge build` — compile contracts
- `forge test` — run the Solidity test suite
- `forge test -vvv` — verbose output
- `forge fmt` — format Solidity sources

Cadence (Flow CLI, run from repo root):
- `./local/run_cadence_tests.sh` — cleans `./db` and `./imports`, installs deps, runs all Cadence tests
- `flow test cadence/tests/<file>.cdc` — run a single Cadence test file (after deps installed)
- `flow deps install --skip-alias --skip-deployments` — install Cadence dependencies

Local full stack (from repo root, in order):
- `./local/setup_and_run_emulator.sh` — start Flow emulator + EVM gateway
- `./local/deploy_full_stack.sh` — deploy Solidity + Cadence contracts; writes EVM address to `./local/.deployed_contract_address`
- `./local/run_solidity_tests.sh` — `forge test` wrapper
- `./local/run_e2e_tests.sh` — user E2E flows (create/deposit/withdraw/close/cancel)
- `./local/run_admin_e2e_tests.sh` — admin E2E flows (allowlist, blocklist, token config, admin cancel/drop)
- `./local/run_worker_tests.sh` — scheduled worker tests (SchedulerHandler, WorkerHandler, pause, crash recovery)

Testnet / ops:
- `./local/deploy_and_verify.sh` — testnet deploy/verify via KMS (requires `.env`; see script header)
- `./local/testnet-e2e.sh --help` — testnet state checks and user/admin actions
- `./scripts/export-artifacts.sh [--network <net> --evm-address 0x...]` — export ABIs and update `deployments/contract-addresses.json`

Scripts expect `flow`, `forge`, `cast`, `curl`, `bc`, `lsof`, and `git` on `PATH`
(see `README.md` "Local Scripts and Sequence").

## Architecture

Solidity (`solidity/`, Foundry):
- `src/FlowYieldVaultsRequests.sol` — single EVM contract; request queue, fund escrow, allowlist/blocklist, `claimableRefunds` pull pattern
- `script/DeployFlowYieldVaultsRequests.s.sol` — deploy script
- `script/FlowYieldVaultsYieldVaultOperations.s.sol` — user operation entrypoints invoked by E2E scripts
- `test/FlowYieldVaultsRequests.t.sol` — Solidity test suite
- `foundry.toml`: solc `0.8.20`, optimizer 200 runs, `via_ir = true`, remapping `@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/`
- Submodules under `solidity/lib/`: `forge-std`, `openzeppelin-contracts`

Cadence (`cadence/`):
- `contracts/FlowYieldVaultsEVM.cdc` — Worker contract: processes EVM requests, manages YieldVault positions, bridges funds via COA
- `contracts/FlowYieldVaultsEVMWorkerOps.cdc` — Orchestration: `SchedulerHandler` (scheduled at `schedulerWakeupInterval`, calls `preprocessRequests`) and `WorkerHandler` (per-request via `processRequest`), including crash recovery
- `transactions/` — user and admin transactions plus `scheduler/` subfolder (init/pause/unpause/destroy handler)
- `scripts/` — read-only queries (pending requests, worker status, yieldvault details) plus `admin/` and `scheduler/` subfolders
- `tests/` — `evm_bridge_lifecycle_test.cdc`, `access_control_test.cdc`, `error_handling_test.cdc`, `validation_test.cdc`, `test_helpers.cdc`, plus `tests/transactions/` helpers

Cross-VM glue:
- `lib/FlowYieldVaults` git submodule — upstream Cadence YieldVaults protocol (`FlowYieldVaults.cdc`, `FlowYieldVaultsClosedBeta.cdc`)
- `flow.json` — aliases per network (`emulator`, `testing`, `testnet`, `mainnet`); deployment order is `FlowYieldVaultsEVMWorkerOps` then `FlowYieldVaultsEVM` to account `emulator-flow-yield-vaults` / `testnet-account` / `mainnet-account`
- `deployments/contract-addresses.json` — source of truth for published EVM and Cadence addresses (testnet + mainnet)

CI (`.github/workflows/`): `unit_tests.yml` (Cadence + Solidity), `e2e_test.yml`, `worker_tests.yml`.

## Conventions and Gotchas

- **Contract versioning (see README "Versioning and Branching")**: `main` is the next FYVEVM generation; `v0` tracks the current production line. Non-upgrade-compatible changes start a new version branch (e.g. `v1`).
- **ABI coupling**: the Cadence worker calls the 5-argument `completeProcessing(uint256,bool,uint64,string,uint256)` on EVM. Deploy Cadence and EVM in lockstep — see README.
- **Sentinel values must stay in sync**: Solidity `NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF`, Solidity `NO_YIELDVAULT_ID = type(uint64).max`, Cadence `UInt64.max` (see `FlowYieldVaultsRequests.sol:105,117`).
- **Request type enum (0–3)** must match across contracts: `CREATE_YIELDVAULT`, `DEPOSIT_TO_YIELDVAULT`, `WITHDRAW_FROM_YIELDVAULT`, `CLOSE_YIELDVAULT`. Only CREATE and DEPOSIT require a deposit.
- **Amount units**: EVM uses wei (10^18); Cadence uses `UFix64`. Convert at the bridge boundary. Precision residuals on successful CREATE/DEPOSIT are credited to `claimableRefunds` (pull pattern via `claimRefund`).
- **Two-phase commit is not atomic across VMs.** Funds are escrowed until processing begins; failed CREATE/DEPOSIT refunds and admin drops go to `claimableRefunds`, not direct sends.
- **Request IDs start at 1**, not 0 (Solidity `nextRequestId` initialized to 1).
- **Cadence test state**: `./local/run_cadence_tests.sh` deletes `./db` and `./imports` before running. Stop the emulator if you need to preserve state.
- **Worker config is runtime-settable** via `FlowYieldVaultsEVMWorkerOps`: `schedulerWakeupInterval` (default 1.0s) and `maxProcessingRequests` (default 3, max concurrent `WorkerHandler`s).
- **Access control**: Only the authorized COA can process requests and withdraw funds on `FlowYieldVaultsRequests`. Deposits are permissionless (to allow gifts/protocol deposits); CREATE/WITHDRAW/CLOSE verify ownership.
- **Test accounts** use well-known private keys `0x2`–`0x6`. Never use on mainnet. The CLAUDE.md and README list the derived addresses.
- **`.github/copilot-instructions.md` is out of date** (references `FlowYieldVaultsTransactionHandler.cdc`, which no longer exists). Prefer `CLAUDE.md` and `README.md` as sources; the only Cadence contracts today are `FlowYieldVaultsEVM.cdc` and `FlowYieldVaultsEVMWorkerOps.cdc`.

## Files Not to Modify

- `lib/FlowYieldVaults/**` — git submodule (upstream YieldVaults protocol)
- `solidity/lib/**` — Foundry submodules (`forge-std`, `openzeppelin-contracts`)
- `deployments/artifacts/**` — generated by `./scripts/export-artifacts.sh`
- `imports/`, `db/`, `solidity/out/`, `solidity/cache/`, `solidity/broadcast/`, `local/.deployed_contract_address` — git-ignored build/runtime artifacts

## Reference Docs

- `README.md` — commands, contract addresses, configuration tables
- `CLAUDE.md` — architecture and blockchain execution model notes
- `FLOW_YIELD_VAULTS_EVM_BRIDGE_DESIGN.md` — detailed bridge design
- `FRONTEND_INTEGRATION.md` — frontend integration guide
- `TESTING.md` — test suite documentation
