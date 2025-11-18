# Flow Vaults EVM Integration

Cross-VM bridge enabling Flow EVM users to access Cadence-based yield farming through asynchronous request processing.

---

## Quick Start

```bash
# 1. Setup & deploy
./local/setup_and_run_emulator.sh && ./local/deploy_full_stack.sh

# 2. Create yield position from EVM
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --sig "runCreateTide(address)" 0xe78a4bF6F7a17CE6fF09219b9E8e10a893819892 \
  --rpc-url localhost:8545 --broadcast --legacy

# 3. Process requests (Cadence worker)
flow transactions send ./cadence/transactions/process_requests.cdc --signer tidal --gas-limit 9999
```

---

## Architecture

```
EVM User → FlowVaultsRequests (escrow) → Worker polls → COA bridges → Tide in Cadence
```

**EVM Side**: Users deposit FLOW and submit requests (CREATE/DEPOSIT/WITHDRAW/CLOSE)  
**Cadence Side**: Worker processes requests, manages Tide positions via COA  
**Bridge**: COA (Cadence Owned Account) controls fund movement between VMs

---

## Operations

All operations use `FlowVaultsTideOperations.s.sol`:

### CREATE_TIDE - Open yield position
```bash
# Default: 10 FLOW
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --sig "runCreateTide(address)" 0xe78a4bF6F7a17CE6fF09219b9E8e10a893819892 \
  --rpc-url localhost:8545 --broadcast --legacy

# Custom amount (100 FLOW)
AMOUNT=100000000000000000000 forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --sig "runCreateTide(address)" 0xe78a4bF6F7a17CE6fF09219b9E8e10a893819892 \
  --rpc-url localhost:8545 --broadcast --legacy
```

### DEPOSIT_TO_TIDE - Add to existing position
```bash
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --sig "runDepositToTide(address,uint64)" 0xe78a4bF6F7a17CE6fF09219b9E8e10a893819892 42 \
  --rpc-url localhost:8545 --broadcast --legacy
```

### WITHDRAW_FROM_TIDE - Withdraw earnings
```bash
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --sig "runWithdrawFromTide(address,uint64,uint256)" 0xe78a4bF6F7a17CE6fF09219b9E8e10a893819892 42 30000000000000000000 \
  --rpc-url localhost:8545 --broadcast --legacy
```

### CLOSE_TIDE - Close position
```bash
forge script ./solidity/script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
  --sig "runCloseTide(address,uint64)" 0xe78a4bF6F7a17CE6fF09219b9E8e10a893819892 42 \
  --rpc-url localhost:8545 --broadcast --legacy
```

---

## Key Contracts

| Component | Address |
|-----------|---------|
| FlowVaultsRequests | `0xe78a4bF6F7a17CE6fF09219b9E8e10a893819892` |
| FlowVaultsEVM | Deployed on Cadence (tidal account) |
| RPC | `localhost:8545` |

---

## Testing

**Status**: ✅ 19/19 tests passing (100%)

```bash
# Run all tests
flow test cadence/tests/evm_bridge_lifecycle_test.cdc
flow test cadence/tests/access_control_test.cdc
flow test cadence/tests/error_handling_test.cdc
```

**Coverage**:
- Request lifecycle (CREATE, DEPOSIT, WITHDRAW, CLOSE) - 8 tests
- Access control & security - 7 tests
- Error handling & edge cases - 4 tests

See `TESTING.md` for complete documentation.

---

## Documentation

- **[Architecture Design](./FLOW_VAULTS_EVM_BRIDGE_DESIGN.md)** - Complete bridge design and data flows
- **[Testing](./TESTING.md)** - Test suite documentation

---

**Built on Flow** | Testnet Deployment Ready