# Frontend Integration Guide

This guide explains how to integrate with the Flow YieldVaults EVM contracts from a frontend application.

## Quick Start

### 1. Add as Git Submodule

```bash
cd your-frontend
git submodule add https://github.com/AneraLabs/FlowYieldVaultsEVM evm-contracts
git submodule update --init --recursive
```

### 2. Access Contract Artifacts

```typescript
import addresses from './evm-contracts/deployments/contract-addresses.json';
import abi from './evm-contracts/deployments/artifacts/FlowYieldVaultsRequests.json';
import { RequestType, RequestStatus } from './evm-contracts/deployments/types';

const contractAddress = addresses.contracts.FlowYieldVaultsRequests.addresses.testnet;
const networkConfig = addresses.metadata.networks.testnet;
```

### 3. Initialize ethers.js Contract

```typescript
import { ethers } from 'ethers';

// Get provider from wallet (e.g., MetaMask)
const provider = new ethers.BrowserProvider(window.ethereum);
const signer = await provider.getSigner();

// Create contract instance
const contract = new ethers.Contract(contractAddress, abi, signer);
```

---

## Contract Functions Reference

### User Operations

#### Create YieldVault
```typescript
// Native FLOW deposit
const NATIVE_FLOW = '0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF';
const amount = ethers.parseEther('10'); // 10 FLOW

const tx = await contract.createYieldVault(
  NATIVE_FLOW,           // tokenAddress
  amount,                // amount
  vaultIdentifier,       // "A.{addr}.FlowToken.Vault"
  strategyIdentifier,    // Strategy identifier
  { value: amount }      // Send FLOW with transaction
);
const receipt = await tx.wait();
```

#### Deposit to Existing YieldVault
```typescript
const tx = await contract.depositToYieldVault(
  yieldVaultId,          // uint64
  NATIVE_FLOW,           // tokenAddress
  amount,                // amount
  { value: amount }
);
await tx.wait();
```

#### Withdraw from YieldVault
```typescript
const tx = await contract.withdrawFromYieldVault(
  yieldVaultId,          // uint64
  amount                 // amount to withdraw
);
await tx.wait();
```

#### Close YieldVault
```typescript
const tx = await contract.closeYieldVault(yieldVaultId);
await tx.wait();
```

#### Cancel Pending Request
```typescript
const tx = await contract.cancelRequest(requestId);
await tx.wait();
```

### Query Functions

#### Get User's YieldVaults
```typescript
const yieldVaultIds: bigint[] = await contract.getYieldVaultIdsForUser(userAddress);
```

#### Check YieldVault Ownership
```typescript
const owns: boolean = await contract.doesUserOwnYieldVault(userAddress, yieldVaultId);
```

#### Get User's Pending Request Count
```typescript
const count: bigint = await contract.getUserPendingRequestCount(userAddress);
```

#### Get User's Escrowed Balance
```typescript
const balance: bigint = await contract.getUserPendingBalance(userAddress, tokenAddress);
```

#### Get Total Pending Request Count
```typescript
const totalPending: bigint = await contract.getPendingRequestCount();
```

#### Get Request Details
```typescript
const request = await contract.getRequest(requestId);
// Returns: { id, user, requestType, status, tokenAddress, amount, yieldVaultId, timestamp, message, vaultIdentifier, strategyIdentifier }
```

#### Get All Pending Requests (Paginated)
```typescript
const [
  ids, users, requestTypes, statuses, tokenAddresses,
  amounts, yieldVaultIds, timestamps, messages,
  vaultIdentifiers, strategyIdentifiers
] = await contract.getPendingRequestsUnpacked(startIndex, count);

// Filter for specific user client-side
const userRequests = ids.filter((_, i) => users[i].toLowerCase() === userAddress.toLowerCase());
```

---

## Request Lifecycle

```
1. User submits request → EVM tx succeeds → RequestCreated event
2. Request queued (status=PENDING)
3. Cadence Worker processes → RequestProcessed event (status=PROCESSING)
4. Operation completes → RequestProcessed event (status=COMPLETED or FAILED)
5. On completion: YieldVault appears in user's list
   On failure: Funds automatically refunded
```

---

## Event Listening

### Listen for Request Status Updates
```typescript
contract.on('RequestCreated', (requestId, user, requestType, tokenAddress, amount, yieldVaultId) => {
  console.log('New request created:', requestId.toString());
  // Add to pending requests UI
});

contract.on('RequestProcessed', (requestId, status, yieldVaultId, message) => {
  console.log('Request processed:', requestId.toString(), 'status:', status);

  if (status === 2) { // COMPLETED
    // Refresh positions list
    fetchPositions();
  } else if (status === 3) { // FAILED
    // Show error message
    showError(message);
  }
});

contract.on('RequestCancelled', (requestId, user, refundAmount) => {
  console.log('Request cancelled, refunded:', ethers.formatEther(refundAmount));
});
```

### Listen for Balance Updates
```typescript
contract.on('BalanceUpdated', (user, tokenAddress, newBalance) => {
  if (user.toLowerCase() === currentUser.toLowerCase()) {
    // Update UI with new escrowed balance
    updateEscrowedBalance(newBalance);
  }
});
```

---

## Cadence Queries (FCL)

The EVM contract only stores **request queue data** and **ownership mappings**. For actual YieldVault position data (balances, yields, strategies), query the Cadence side using [Flow Client Library (FCL)](https://developers.flow.com/tools/clients/fcl-js).

### Setup FCL

```typescript
import * as fcl from '@onflow/fcl';

// Configure for testnet
fcl.config({
  'accessNode.api': 'https://rest-testnet.onflow.org',
  'flow.network': 'testnet',
});

// Contract addresses
const FLOW_YIELD_VAULTS_EVM_ADDRESS = '0x4135b56ffc55ecef'; // testnet
```

### Get User's YieldVault IDs (from Cadence)

```typescript
const GET_USER_YIELDVAULTS = `
import FlowYieldVaultsEVM from 0x4135b56ffc55ecef

access(all) fun main(evmAddress: String): [UInt64] {
    var normalizedAddress = evmAddress.toLower()
    if normalizedAddress.length > 2 && normalizedAddress.slice(from: 0, upTo: 2) == "0x" {
        normalizedAddress = normalizedAddress.slice(from: 2, upTo: normalizedAddress.length)
    }
    while normalizedAddress.length < 40 {
        normalizedAddress = "0".concat(normalizedAddress)
    }
    return FlowYieldVaultsEVM.getYieldVaultIdsForEVMAddress(normalizedAddress)
}
`;

const yieldVaultIds = await fcl.query({
  cadence: GET_USER_YIELDVAULTS,
  args: (arg, t) => [arg(userEvmAddress, t.String)],
});
```

### Get YieldVault Balance

This is **critical** for displaying actual position values. The balance lives on Cadence, not EVM.

```typescript
const GET_YIELDVAULT_BALANCE = `
import FlowYieldVaults from 0x4135b56ffc55ecef

access(all) fun main(managerAddress: Address, yieldVaultId: UInt64): UFix64? {
    let account = getAccount(managerAddress)
    if let manager = account.capabilities.borrow<&FlowYieldVaults.YieldVaultManager>(
        FlowYieldVaults.YieldVaultManagerPublicPath
    ) {
        if let yieldVault = manager.borrowYieldVault(id: yieldVaultId) {
            return yieldVault.getYieldVaultBalance()
        }
    }
    return nil
}
`;

const balance = await fcl.query({
  cadence: GET_YIELDVAULT_BALANCE,
  args: (arg, t) => [
    arg(FLOW_YIELD_VAULTS_EVM_ADDRESS, t.Address),
    arg(yieldVaultId.toString(), t.UInt64),
  ],
});
// Returns UFix64 string like "100.00000000"
```

### Get YieldVault Details (Balance + Strategy)

```typescript
const GET_YIELDVAULT_DETAILS = `
import FlowYieldVaults from 0x4135b56ffc55ecef

access(all) fun main(managerAddress: Address, yieldVaultId: UInt64): {String: AnyStruct}? {
    let account = getAccount(managerAddress)
    if let manager = account.capabilities.borrow<&FlowYieldVaults.YieldVaultManager>(
        FlowYieldVaults.YieldVaultManagerPublicPath
    ) {
        if let yieldVault = manager.borrowYieldVault(id: yieldVaultId) {
            return {
                "id": yieldVaultId,
                "balance": yieldVault.getYieldVaultBalance(),
                "supportedVaultTypes": yieldVault.getSupportedVaultTypes().keys
            }
        }
    }
    return nil
}
`;

const details = await fcl.query({
  cadence: GET_YIELDVAULT_DETAILS,
  args: (arg, t) => [
    arg(FLOW_YIELD_VAULTS_EVM_ADDRESS, t.Address),
    arg(yieldVaultId.toString(), t.UInt64),
  ],
});
```

### Get All User Positions with Balances

Combine EVM ownership with Cadence balance data:

```typescript
async function getUserPositions(userEvmAddress: string) {
  // 1. Get YieldVault IDs from Cadence (faster than EVM call)
  const yieldVaultIds = await fcl.query({
    cadence: GET_USER_YIELDVAULTS,
    args: (arg, t) => [arg(userEvmAddress, t.String)],
  });

  // 2. Fetch balances for each YieldVault
  const positions = await Promise.all(
    yieldVaultIds.map(async (id: string) => {
      const balance = await fcl.query({
        cadence: GET_YIELDVAULT_BALANCE,
        args: (arg, t) => [
          arg(FLOW_YIELD_VAULTS_EVM_ADDRESS, t.Address),
          arg(id, t.UInt64),
        ],
      });
      return {
        yieldVaultId: id,
        balance: parseFloat(balance || '0'),
      };
    })
  );

  return positions;
}
```

### Get Supported Strategies

```typescript
const GET_SUPPORTED_STRATEGIES = `
import FlowYieldVaults from 0x4135b56ffc55ecef

access(all) fun main(): [String] {
    let strategies = FlowYieldVaults.getSupportedStrategies()
    let identifiers: [String] = []
    for strategy in strategies {
        identifiers.append(strategy.identifier)
    }
    return identifiers
}
`;

const strategies = await fcl.query({ cadence: GET_SUPPORTED_STRATEGIES });
// Returns: ["A.xxx.FlowYieldVaultsStrategies.IncrementFiLiquidStaking", ...]
```

### Check Worker/System Status

```typescript
const CHECK_SYSTEM_STATUS = `
import FlowYieldVaultsEVM from 0x4135b56ffc55ecef

access(all) fun main(): {String: AnyStruct} {
    return {
        "flowYieldVaultsRequestsAddress": FlowYieldVaultsEVM.getFlowYieldVaultsRequestsAddress()?.toString() ?? "not set",
        "totalEVMUsers": FlowYieldVaultsEVM.yieldVaultsByEVMAddress.keys.length
    }
}
`;

const status = await fcl.query({ cadence: CHECK_SYSTEM_STATUS });
```

### EVM vs Cadence Query Comparison

| Data | Query From | Why |
|------|------------|-----|
| Pending requests | EVM | Request queue lives on EVM |
| Request status | EVM | Status updates happen on EVM |
| User owns YieldVault | **Either** | Both maintain ownership mappings |
| YieldVault balance | **Cadence** | Actual position value is on Cadence |
| Yield/rewards | **Cadence** | Strategy execution is on Cadence |
| Supported strategies | **Cadence** | Strategy registry is on Cadence |

### Recommended Frontend Data Flow

```typescript
// On page load
async function initializeUserDashboard(evmAddress: string) {
  // 1. Get owned YieldVault IDs (Cadence - fast)
  const yieldVaultIds = await fcl.query({
    cadence: GET_USER_YIELDVAULTS,
    args: (arg, t) => [arg(evmAddress, t.String)],
  });

  // 2. Get pending requests (EVM)
  const pendingCount = await evmContract.getUserPendingRequestCount(evmAddress);

  // 3. Fetch balances for active positions (Cadence)
  const positions = await Promise.all(
    yieldVaultIds.map(id => getYieldVaultDetails(id))
  );

  // 4. Subscribe to EVM events for real-time updates
  evmContract.on('RequestProcessed', handleRequestProcessed);

  return { positions, pendingCount };
}
```

---

## Critical UX Requirements

> "Users must know the exact status of their money at all times" - Tom

### Display Requirements
1. **Pending Requests Panel**: Show all user's pending/processing requests
2. **Real-time Updates**: PENDING → PROCESSING → COMPLETED/FAILED
3. **Clear Messaging**: "Your transaction is being processed. This typically takes 15-60 seconds."
4. **Escrowed Balance**: Show funds held in escrow during processing

### Flow vs EVM Wallet Differences

| Aspect | Flow Wallet | EVM Wallet |
|--------|-------------|------------|
| Transaction Time | ~10 seconds | ~15-60 seconds (two-step) |
| Optimistic Updates | YES | NO |
| UI Behavior | Immediate position | Show in "Pending" first |

**Important:** Do NOT apply optimistic updates for EVM wallets!

```typescript
if (wallet.type === 'evm') {
  // Show in pending requests UI
  // Wait for RequestProcessed event with status=COMPLETED
  // Then move to main positions list
} else {
  // Existing Flow wallet optimistic logic
}
```

---

## Constants

```typescript
// Sentinel address for native FLOW token
const NATIVE_FLOW = '0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF';

// Sentinel value for "no YieldVault" (used before creation completes)
const NO_YIELDVAULT_ID = 18446744073709551615n; // type(uint64).max

// Request Types
enum RequestType {
  CREATE_YIELDVAULT = 0,
  DEPOSIT_TO_YIELDVAULT = 1,
  WITHDRAW_FROM_YIELDVAULT = 2,
  CLOSE_YIELDVAULT = 3
}

// Request Status
enum RequestStatus {
  PENDING = 0,
  PROCESSING = 1,
  COMPLETED = 2,
  FAILED = 3
}
```

---

## Testing Checklist

- [ ] User can connect EVM wallet
- [ ] Create YieldVault request submits successfully
- [ ] Request appears in Pending Requests panel immediately
- [ ] Status updates automatically (PENDING → PROCESSING → COMPLETED)
- [ ] Completed YieldVault appears in main positions list
- [ ] User can cancel pending request (only PENDING status)
- [ ] Failed requests show clear error messages
- [ ] Escrowed balance displays correctly

---

## TypeScript Types

Full type definitions are available in `deployments/types/index.ts`:

```typescript
import {
  RequestType,
  RequestStatus,
  EVMRequest,
  RequestCreatedEvent,
  RequestProcessedEvent,
  RequestCancelledEvent,
  NO_YIELD_VAULT_ID,
  NATIVE_FLOW_ADDRESS,
  isRequestPending,
  isRequestCompleted,
  getRequestTypeName,
  getRequestStatusName
} from './evm-contracts/deployments/types';
```

---

## Support

### EVM Resources
- **Contract ABI**: `deployments/artifacts/FlowYieldVaultsRequests.json`
- **Contract Addresses**: `deployments/contract-addresses.json`
- **Event Definitions**: See TypeScript types or ABI

### Cadence Resources
- **FCL Documentation**: [developers.flow.com/tools/clients/fcl-js](https://developers.flow.com/tools/clients/fcl-js)
- **Cadence Scripts**: `cadence/scripts/` directory
  - `check_user_yieldvaults.cdc` - Get YieldVault IDs for EVM address
  - `check_yieldvault_details.cdc` - Get system-wide YieldVault details
  - `check_yieldvaultmanager_status.cdc` - Comprehensive system status
  - `check_worker_status.cdc` - Worker health checks

### Architecture
- **Design Document**: [FLOW_VAULTS_EVM_BRIDGE_DESIGN.md](./FLOW_VAULTS_EVM_BRIDGE_DESIGN.md)
