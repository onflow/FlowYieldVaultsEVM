# EVM Integration Implementation Guide

This document contains all the modifications needed for the FlowYieldVaultsEVM repository to support Tom's frontend integration and backend event indexing.

**Based on conversation with Tom (Nov 24, 2025)** - See transcript for full context about requirements.

---

## Summary of Changes

1. **Deployment Artifacts System** - Export contract ABIs and addresses for frontend consumption
2. **Enhanced Solidity Getters** - Add user-specific and queue status query functions
3. **Cadence Query Scripts** - Scripts for backend to query EVM contract state
4. **TypeScript Types** - Type definitions for frontend integration
5. **Documentation** - Integration guides for Tom and backend team

---

## Part 1: Deployment Artifacts System

### 1.1 Create `deployments/contract-addresses.json`

**Location:** `/deployments/contract-addresses.json`

```json
{
  "contracts": {
    "FlowYieldVaultsRequests": {
      "abi": "./artifacts/FlowYieldVaultsRequests.json",
      "addresses": {
        "testnet": "0x935936B21B397902B786B55A21d3CB3863C9E814",
        "mainnet": "0x0000000000000000000000000000000000000000"
      }
    },
    "FlowYieldVaultsEVM": {
      "network": "flow",
      "addresses": {
        "testnet": "0xd2580caf2ef07c2f",
        "mainnet": "0x0000000000000000000000000000"
      }
    }
  },
  "metadata": {
    "version": "1.0.0",
    "lastUpdated": "2024-12-02T00:00:00Z",
    "networks": {
      "testnet": {
        "chainId": "545",
        "name": "Flow EVM Testnet",
        "rpcUrl": "https://testnet.evm.nodes.onflow.org"
      },
      "mainnet": {
        "chainId": "747",
        "name": "Flow EVM Mainnet",
        "rpcUrl": "https://mainnet.evm.nodes.onflow.org"
      }
    }
  }
}
```

**Note:** Update the testnet address after deployment. Mainnet address placeholder for now.

### 1.2 Create `scripts/export-artifacts.sh`

**Location:** `/scripts/export-artifacts.sh`

```bash
#!/bin/bash
# Export ABIs to frontend-friendly format

set -e

echo "Exporting contract artifacts..."

# Create directories if they don't exist
mkdir -p deployments/artifacts

# Build contracts
echo "Building contracts..."
forge build

# Extract ABI
echo "Extracting FlowYieldVaultsRequests ABI..."
jq '.abi' out/FlowYieldVaultsRequests.sol/FlowYieldVaultsRequests.json > deployments/artifacts/FlowYieldVaultsRequests.json

echo "Artifacts exported successfully to deployments/artifacts/"
echo "- FlowYieldVaultsRequests.json (ABI only)"
echo ""
echo "Don't forget to update deployments/contract-addresses.json with deployment addresses!"
```

**Make executable:** `chmod +x scripts/export-artifacts.sh`

**Usage:**
```bash
./scripts/export-artifacts.sh
```

### 1.3 Extract ABI to Artifacts

**Run after building contracts:**

```bash
mkdir -p deployments/artifacts
jq '.abi' out/FlowYieldVaultsRequests.sol/FlowYieldVaultsRequests.json > deployments/artifacts/FlowYieldVaultsRequests.json
```

This creates a clean ABI-only JSON file (no compiler metadata) that's ~1600 lines.

---

## Part 2: TypeScript Type Definitions

### 2.1 Create `deployments/types/index.ts`

**Location:** `/deployments/types/index.ts`

```typescript
// TypeScript type definitions for Flow Yield Vaults EVM Integration
// This file provides type-safe interfaces for frontend integration

// Request types matching Solidity enums
export enum RequestType {
  CREATE_YIELD_VAULT = 0,
  DEPOSIT_TO_YIELD_VAULT = 1,
  WITHDRAW_FROM_YIELD_VAULT = 2,
  CLOSE_YIELD_VAULT = 3,
}

export enum RequestStatus {
  PENDING = 0,
  PROCESSING = 1,
  COMPLETED = 2,
  FAILED = 3,
}

// Request structure mirroring Solidity struct
export interface EVMRequest {
  id: string;                    // uint256 as string
  user: string;                  // address
  requestType: RequestType;
  status: RequestStatus;
  tokenAddress: string;          // address
  amount: string;                // uint256 as string
  yieldVaultId: string;                // uint64 as string (NO_YIELD_VAULT_ID = type(uint64).max)
  timestamp: number;             // uint256 as number
  message: string;               // string
  vaultIdentifier: string;       // string
  strategyIdentifier: string;    // string
}

// Queue status information
export interface QueueStatus {
  totalPending: number;          // Total requests in queue
  userPending: number;           // User's pending requests
  userPosition: number;          // Position in queue (0-indexed)
  estimatedWaitSeconds: number;  // Estimated wait time
}

// Event interfaces for contract events

export interface RequestCreatedEvent {
  requestId: string;
  user: string;
  requestType: RequestType;
  tokenAddress: string;
  amount: string;
  yieldVaultId: string;
}

export interface RequestProcessedEvent {
  requestId: string;
  status: RequestStatus;
  yieldVaultId: string;
  message: string;
}

export interface RequestCancelledEvent {
  requestId: string;
  user: string;
  refundAmount: string;
}

export interface Yield VaultCreatedForEVMUserEvent {
  evmAddress: string;
  yieldVaultId: string;
  amount: string;
}

export interface Yield VaultDepositedForEVMUserEvent {
  evmAddress: string;
  yieldVaultId: string;
  amount: string;
  isYield VaultOwner: boolean;
}

export interface Yield VaultWithdrawnForEVMUserEvent {
  evmAddress: string;
  yieldVaultId: string;
  amount: string;
}

export interface Yield VaultClosedForEVMUserEvent {
  evmAddress: string;
  yieldVaultId: string;
  amountReturned: string;
}

// Helper type for request type names
export type RequestTypeName = 'CREATE_YIELD_VAULT' | 'DEPOSIT_TO_YIELD_VAULT' | 'WITHDRAW_FROM_YIELD_VAULT' | 'CLOSE_YIELD_VAULT';

// Helper type for request status names
export type RequestStatusName = 'PENDING' | 'PROCESSING' | 'COMPLETED' | 'FAILED';

// Utility function types
export interface ContractAddresses {
  FlowYieldVaultsRequests: {
    abi: string;
    addresses: {
      testnet: string;
      mainnet: string;
    };
  };
  FlowYieldVaultsEVM: {
    network: 'flow';
    addresses: {
      testnet: string;
      mainnet: string;
    };
  };
}

export interface NetworkMetadata {
  chainId: string;
  name: string;
  rpcUrl: string;
}

export interface DeploymentManifest {
  contracts: ContractAddresses;
  metadata: {
    version: string;
    lastUpdated: string;
    networks: {
      testnet: NetworkMetadata;
      mainnet: NetworkMetadata;
    };
  };
}

// Constants
export const NO_YIELD_VAULT_ID = '18446744073709551615'; // type(uint64).max
export const NATIVE_FLOW_ADDRESS = '0xFFfFfFfFfFfFfFfFfFfFfFfFfFfFfFfFfFfFfFfF';

// Type guards
export function isRequestPending(status: RequestStatus): boolean {
  return status === RequestStatus.PENDING;
}

export function isRequestProcessing(status: RequestStatus): boolean {
  return status === RequestStatus.PROCESSING;
}

export function isRequestCompleted(status: RequestStatus): boolean {
  return status === RequestStatus.COMPLETED;
}

export function isRequestFailed(status: RequestStatus): boolean {
  return status === RequestStatus.FAILED;
}

export function isRequestActive(status: RequestStatus): boolean {
  return status === RequestStatus.PENDING || status === RequestStatus.PROCESSING;
}

// Request type helpers
export function getRequestTypeName(type: RequestType): RequestTypeName {
  const names: Record<RequestType, RequestTypeName> = {
    [RequestType.CREATE_YIELD_VAULT]: 'CREATE_YIELD_VAULT',
    [RequestType.DEPOSIT_TO_YIELD_VAULT]: 'DEPOSIT_TO_YIELD_VAULT',
    [RequestType.WITHDRAW_FROM_YIELD_VAULT]: 'WITHDRAW_FROM_YIELD_VAULT',
    [RequestType.CLOSE_YIELD_VAULT]: 'CLOSE_YIELD_VAULT',
  };
  return names[type];
}

export function getRequestStatusName(status: RequestStatus): RequestStatusName {
  const names: Record<RequestStatus, RequestStatusName> = {
    [RequestStatus.PENDING]: 'PENDING',
    [RequestStatus.PROCESSING]: 'PROCESSING',
    [RequestStatus.COMPLETED]: 'COMPLETED',
    [RequestStatus.FAILED]: 'FAILED',
  };
  return names[status];
}

// Export all types
export type {
  EVMRequest as Request,
  QueueStatus,
  RequestCreatedEvent,
  RequestProcessedEvent,
  RequestCancelledEvent,
  Yield VaultCreatedForEVMUserEvent,
  Yield VaultDepositedForEVMUserEvent,
  Yield VaultWithdrawnForEVMUserEvent,
  Yield VaultClosedForEVMUserEvent,
  ContractAddresses,
  NetworkMetadata,
  DeploymentManifest,
};
```

---

## Part 3: Enhanced Solidity Getters

### 3.1 Add New View Functions to `FlowYieldVaultsRequests.sol`

**Location:** `solidity/src/FlowYieldVaultsRequests.sol`

**Insert these functions after `doesUserOwnYieldVault` (around line 1009) and before the "Internal Functions" comment:**

```solidity
    /// @notice Gets all pending request ids for a specific user
    /// @dev Two-pass algorithm: count then collect for gas efficiency
    /// @param user User address
    /// @return Array of request ids belonging to the user
    function getPendingRequestIdsForUser(
        address user
    ) external view returns (uint256[] memory) {
        // First pass: count matching requests
        uint256 count = 0;
        for (uint256 i = 0; i < pendingRequestIds.length; ) {
            if (requests[pendingRequestIds[i]].user == user) {
                count++;
            }
            unchecked {
                ++i;
            }
        }

        // Second pass: collect matching request ids
        uint256[] memory userRequestIds = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < pendingRequestIds.length; ) {
            uint256 reqId = pendingRequestIds[i];
            if (requests[reqId].user == user) {
                userRequestIds[idx++] = reqId;
            }
            unchecked {
                ++i;
            }
        }
        return userRequestIds;
    }

    /// @notice Gets full details of pending requests for a specific user
    /// @dev Returns parallel arrays optimized for frontend consumption
    /// @param user User address
    /// @return ids Request ids
    /// @return users User addresses (all same as input user)
    /// @return requestTypes Request types
    /// @return statuses Request statuses
    /// @return tokenAddresses Token addresses
    /// @return amounts Amounts
    /// @return yieldVaultIds Yield Vault ids
    /// @return timestamps Timestamps
    function getPendingRequestsForUser(
        address user
    )
        external
        view
        returns (
            uint256[] memory ids,
            address[] memory users,
            uint8[] memory requestTypes,
            uint8[] memory statuses,
            address[] memory tokenAddresses,
            uint256[] memory amounts,
            uint64[] memory yieldVaultIds,
            uint256[] memory timestamps
        )
    {
        // Get user's request ids first
        uint256[] memory userIds = this.getPendingRequestIdsForUser(user);
        uint256 length = userIds.length;

        // Initialize arrays
        ids = new uint256[](length);
        users = new address[](length);
        requestTypes = new uint8[](length);
        statuses = new uint8[](length);
        tokenAddresses = new address[](length);
        amounts = new uint256[](length);
        yieldVaultIds = new uint64[](length);
        timestamps = new uint256[](length);

        // Populate arrays
        for (uint256 i = 0; i < length; ) {
            Request memory req = requests[userIds[i]];
            ids[i] = req.id;
            users[i] = req.user;
            requestTypes[i] = uint8(req.requestType);
            statuses[i] = uint8(req.status);
            tokenAddresses[i] = req.tokenAddress;
            amounts[i] = req.amount;
            yieldVaultIds[i] = req.yieldVaultId;
            timestamps[i] = req.timestamp;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Gets the queue position for a specific request
    /// @dev Returns type(uint256).max if request not found in queue
    /// @param requestId Request id to look up
    /// @return position Queue position (0-indexed), or type(uint256).max if not found
    function getQueuePosition(
        uint256 requestId
    ) external view returns (uint256 position) {
        for (uint256 i = 0; i < pendingRequestIds.length; ) {
            if (pendingRequestIds[i] == requestId) {
                return i;
            }
            unchecked {
                ++i;
            }
        }
        return type(uint256).max;
    }

    /// @notice Gets estimated processing time based on queue position
    /// @dev Uses rough estimate of 15 seconds per request
    /// @param requestId Request id to estimate
    /// @return estimatedSeconds Estimated seconds until processing (0 if not found)
    function getEstimatedProcessingTime(
        uint256 requestId
    ) external view returns (uint256 estimatedSeconds) {
        uint256 position = this.getQueuePosition(requestId);
        if (position == type(uint256).max) return 0;

        // Rough estimate: 15 seconds per request
        // This can be adjusted based on actual processing data
        return position * 15;
    }
```

**Why these functions:**
- `getPendingRequestIdsForUser()` - Backend needs to query specific user's requests
- `getPendingRequestsForUser()` - Frontend gets full request details for UI display
- `getQueuePosition()` - Shows user "You are #3 in queue"
- `getEstimatedProcessingTime()` - Shows "~45 seconds" estimated wait

---

## Part 4: Cadence Query Scripts

### 4.1 Create `cadence/scripts/get_pending_requests_for_user.cdc`

**Location:** `/cadence/scripts/get_pending_requests_for_user.cdc`

```cadence
import FlowYieldVaultsEVM from "../contracts/FlowYieldVaultsEVM.cdc"
import EVM from 0x1

/// Get all pending request ids for an EVM user
/// @param evmUserAddress - EVM address as hex string (e.g., "0x1234...")
/// @return Array of request ids as UInt256
access(all) fun main(evmUserAddress: String): [UInt256] {
    // Convert hex string to EVM address
    let evmAddr = EVM.addressFromString(evmUserAddress)

    // Get the FlowYieldVaultsRequests contract address from FlowYieldVaultsEVM
    let requestsAddr = FlowYieldVaultsEVM.getFlowYieldVaultsRequestsAddress()
        ?? panic("FlowYieldVaultsRequests address not set in FlowYieldVaultsEVM")

    // Encode function call: getPendingRequestIdsForUser(address)
    let calldata = EVM.encodeABIWithSignature(
        "getPendingRequestIdsForUser(address)",
        [evmAddr]
    )

    // Execute view call on EVM contract
    let result = EVM.call(
        to: requestsAddr,
        data: calldata,
        gasLimit: 1000000,
        value: EVM.Balance(attoflow: 0)
    )

    // Decode uint256[] return value
    let decoded = EVM.decodeABI(types: [Type<[UInt256]>()], data: result.data)
    return decoded[0] as! [UInt256]
}
```

**Usage:**
```bash
flow scripts execute cadence/scripts/get_pending_requests_for_user.cdc "0x1234..."
```

### 4.2 Create `cadence/scripts/get_queue_status.cdc`

**Location:** `/cadence/scripts/get_queue_status.cdc`

```cadence
import FlowYieldVaultsEVM from "../contracts/FlowYieldVaultsEVM.cdc"
import EVM from 0x1

/// Queue status information
access(all) struct QueueStatus {
    access(all) let totalPending: UInt256
    access(all) let userPending: UInt256
    access(all) let userPosition: UInt256
    access(all) let estimatedWaitSeconds: UInt256

    init(totalPending: UInt256, userPending: UInt256, userPosition: UInt256, estimatedWaitSeconds: UInt256) {
        self.totalPending = totalPending
        self.userPending = userPending
        self.userPosition = userPosition
        self.estimatedWaitSeconds = estimatedWaitSeconds
    }
}

/// Get comprehensive queue status for a user's specific request
/// @param evmUserAddress - EVM address as hex string
/// @param requestId - Request id as UInt256
/// @return QueueStatus struct with all queue information
access(all) fun main(evmUserAddress: String, requestId: UInt256): QueueStatus {
    let requestsAddr = FlowYieldVaultsEVM.getFlowYieldVaultsRequestsAddress()
        ?? panic("FlowYieldVaultsRequests address not set")

    // Get total pending count
    let totalPending = getPendingCount(requestsAddr)

    // Get user-specific pending count
    let userPending = getUserPendingCount(requestsAddr, evmUserAddress)

    // Get this request's position in queue
    let position = getQueuePosition(requestsAddr, requestId)

    // Get estimated processing time
    let estimatedTime = getEstimatedTime(requestsAddr, requestId)

    return QueueStatus(
        totalPending: totalPending,
        userPending: userPending,
        userPosition: position,
        estimatedWaitSeconds: estimatedTime
    )
}

// Helper functions

access(all) fun getPendingCount(_ addr: EVM.EVMAddress): UInt256 {
    let calldata = EVM.encodeABIWithSignature("getPendingRequestCount()", [])
    let result = EVM.call(to: addr, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
    let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: result.data)
    return decoded[0] as! UInt256
}

access(all) fun getUserPendingCount(_ addr: EVM.EVMAddress, _ userAddress: String): UInt256 {
    let evmAddr = EVM.addressFromString(userAddress)
    let calldata = EVM.encodeABIWithSignature("getUserPendingRequestCount(address)", [evmAddr])
    let result = EVM.call(to: addr, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
    let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: result.data)
    return decoded[0] as! UInt256
}

access(all) fun getQueuePosition(_ addr: EVM.EVMAddress, _ requestId: UInt256): UInt256 {
    let calldata = EVM.encodeABIWithSignature("getQueuePosition(uint256)", [requestId])
    let result = EVM.call(to: addr, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
    let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: result.data)
    return decoded[0] as! UInt256
}

access(all) fun getEstimatedTime(_ addr: EVM.EVMAddress, _ requestId: UInt256): UInt256 {
    let calldata = EVM.encodeABIWithSignature("getEstimatedProcessingTime(uint256)", [requestId])
    let result = EVM.call(to: addr, data: calldata, gasLimit: 100000, value: EVM.Balance(attoflow: 0))
    let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: result.data)
    return decoded[0] as! UInt256
}
```

**Usage:**
```bash
flow scripts execute cadence/scripts/get_queue_status.cdc "0x1234..." 42
```

### 4.3 Create `cadence/scripts/get_yield_vault_ownership.cdc`

**Location:** `/cadence/scripts/get_yield_vault_ownership.cdc`

```cadence
import FlowYieldVaultsEVM from "../contracts/FlowYieldVaultsEVM.cdc"

/// Get all Yield Vault ids owned by an EVM address
/// @param evmAddress - EVM address as hex string
/// @return Array of Yield Vault ids (UInt64)
access(all) fun main(evmAddress: String): [UInt64] {
    return FlowYieldVaultsEVM.getYield VaultidsForEVMAddress(evmAddress: evmAddress)
}
```

**Usage:**
```bash
flow scripts execute cadence/scripts/get_yield_vault_ownership.cdc "0x1234..."
```

---

## Part 5: Frontend Integration Documentation

### 5.1 Create `FRONTEND_INTEGRATION.md`

**Location:** `/FRONTEND_INTEGRATION.md`

```markdown
# Frontend Integration Guide

This guide explains how Tom's frontend (tidal-fe) should integrate with the EVM contracts.

## Quick Start

### 1. Add as Git Submodule

```bash
cd tidal-fe
git submodule add https://github.com/your-org/FlowYieldVaultsEVM evm-contracts
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

## Key Integration Points

### Request Lifecycle

```
1. User submits → EVM tx succeeds → RequestCreated event
2. Request in queue → Query getQueuePosition() for position
3. Cadence processes → RequestProcessed event (status=PROCESSING)
4. Yield Vault created → RequestProcessed event (status=COMPLETED)
5. Position appears in main list
```

### Critical UX Requirements (from Tom's call)

> "Users must know the exact status of their money at all times" - Tom

**Display Requirements:**
1. **Queue Position**: "You are #3 in queue"
2. **Estimated Wait**: "~45 seconds"
3. **Real-time Updates**: PENDING → PROCESSING → COMPLETED
4. **Clear Messaging**: "Your transaction is being processed on the Cadence side. This typically takes 15-60 seconds."

### Contract Functions to Call

**Submit Create Yield Vault Request:**
```typescript
const tx = await contract.createYield Vault(
  tokenAddress,      // 0xFFfF...FfF for native FLOW
  amount,            // bigint
  vaultIdentifier,   // "A.{addr}.FlowToken.Vault"
  strategyIdentifier // Strategy id
);
const receipt = await tx.wait();

// Extract requestId from RequestCreated event
const event = receipt.logs.find(log =>
  log.topics[0] === ethers.id('RequestCreated(uint256,address,uint8,address,uint256,uint64)')
);
const requestId = ethers.AbiCoder.defaultAbiCoder().decode(['uint256'], event.topics[1])[0];
```

**Query User's Pending Requests:**
```typescript
const result = await contract.getPendingRequestsForUser(userAddress);
// Returns parallel arrays: ids, users, requestTypes, statuses, tokenAddresses, amounts, yieldVaultIds, timestamps
```

**Get Queue Status:**
```typescript
const position = await contract.getQueuePosition(requestId);
const estimatedSeconds = await contract.getEstimatedProcessingTime(requestId);
```

**Cancel Request:**
```typescript
const tx = await contract.cancelRequest(requestId);
await tx.wait();
```

### Event Listening

**Listen for status updates:**
```typescript
contract.on('RequestProcessed', (requestId, status, yieldVaultId, message) => {
  console.log('Request', requestId.toString(), 'status:', status);

  if (status === 2) { // COMPLETED
    // Refresh positions list
    fetchPositions();
  }
});
```

## Important: Flow vs EVM Wallet Differences

### Flow Wallet (Current Behavior)
- Transaction: ~10 seconds (single-step)
- Optimistic Updates: YES - position appears instantly
- UI Behavior: Immediate feedback, reconciles later

### EVM Wallet (New Behavior)
- Transaction: ~15-60 seconds (two-step: request + processing)
- Optimistic Updates: NO - wait for actual processing
- UI Behavior: Show in "Pending Requests" panel

**DO NOT apply optimistic updates for EVM wallets!**

```typescript
if (wallet.type === 'evm') {
  // NO optimistic updates
  // NO immediate position creation
  // YES pending request entry
  // YES show in pending requests UI
} else {
  // Existing Flow wallet optimistic logic
}
```

## Backend API Integration

The backend will provide these endpoints:

**Get Pending Requests:**
```
GET /api/wallets/:walletAddress/evm-pending-requests
```

Returns:
```json
[
  {
    "id": "123",
    "user": "0x...",
    "requestType": "CREATE_YIELD_VAULT",
    "status": "PENDING",
    "tokenAddress": "0xFFfF...FfF",
    "amount": "100000000",
    "queuePosition": 2,
    "estimatedWaitSeconds": 45,
    "timestamp": 1701234567
  }
]
```

## Testing Checklist

- [ ] User can connect EVM wallet via unified selector
- [ ] Create Yield Vault request submits successfully
- [ ] Request appears in Pending Requests panel immediately
- [ ] Queue position and wait time display correctly
- [ ] Status updates automatically (PENDING → PROCESSING → COMPLETED)
- [ ] Completed position appears in main positions list
- [ ] User can cancel pending request
- [ ] Clear error messages on failure

## Support

For questions or issues:
- Contract events: See event definitions in TypeScript types
- Integration patterns: Follow existing Flow wallet patterns
- Backend coordination: Ensure backend is indexing EVM events
```

---

## Part 6: README Updates

### 6.1 Add Section to `README.md`

**Location:** `README.md`

**Insert this section after the "Quick Start" section:**

```markdown
## Frontend Integration

### Contract Artifacts

Contract ABIs and addresses are available in `deployments/`:
- `contract-addresses.json` - Network-specific contract addresses
- `artifacts/FlowYieldVaultsRequests.json` - Solidity contract ABI
- `types/index.ts` - TypeScript type definitions

### Git Submodule Setup

Frontend developers can add this repo as a submodule:

```bash
git submodule add https://github.com/your-org/FlowYieldVaultsEVM evm-contracts
git submodule update --init --recursive
```

Access artifacts in your frontend:

```typescript
import addresses from './evm-contracts/deployments/contract-addresses.json';
import abi from './evm-contracts/deployments/artifacts/FlowYieldVaultsRequests.json';

const contractAddress = addresses.contracts.FlowYieldVaultsRequests.addresses.testnet;
```

### Exporting Artifacts

After building or deploying contracts:

```bash
./scripts/export-artifacts.sh
```

This exports the ABI to `deployments/artifacts/` for frontend consumption.

### Pending Request Status Flow

1. **User submits request** → `RequestCreated` event emitted
2. **Request enters queue** → Query `getQueuePosition(requestId)` for position
3. **Processing starts** → `RequestProcessed` event with status=PROCESSING
4. **Cadence operations** → Yield Vault created/updated on Cadence side
5. **Completion** → `RequestProcessed` event with status=COMPLETED/FAILED

### Key Scripts for Backend Integration

**Get user's pending requests:**
```bash
flow scripts execute cadence/scripts/get_pending_requests_for_user.cdc "0x1234..."
```

**Get queue status:**
```bash
flow scripts execute cadence/scripts/get_queue_status.cdc "0x1234..." 42
```

**Get Yield Vault ownership:**
```bash
flow scripts execute cadence/scripts/get_yield_vault_ownership.cdc "0x1234..."
```

For detailed integration instructions, see [FRONTEND_INTEGRATION.md](./FRONTEND_INTEGRATION.md).
```

---

## Part 7: Deployment Checklist

### After Implementing These Changes

1. **Build and Test Contracts**
   ```bash
   forge build
   forge test
   ```

2. **Export Artifacts**
   ```bash
   ./scripts/export-artifacts.sh
   ```

3. **Deploy to Testnet**
   ```bash
   ./deploy_and_verify.sh
   ```

4. **Update Contract Address**
   - Edit `deployments/contract-addresses.json`
   - Update `testnet` address with deployed address

5. **Test New Getters**
   ```bash
   # Test user-specific getter
   cast call <CONTRACT_ADDRESS> "getPendingRequestIdsForUser(address)" <USER_ADDRESS> --rpc-url https://testnet.evm.nodes.onflow.org

   # Test queue position
   cast call <CONTRACT_ADDRESS> "getQueuePosition(uint256)" <REQUEST_ID> --rpc-url https://testnet.evm.nodes.onflow.org
   ```

6. **Test Cadence Scripts**
   ```bash
   flow scripts execute cadence/scripts/get_pending_requests_for_user.cdc "0x..."
   flow scripts execute cadence/scripts/get_queue_status.cdc "0x..." 42
   flow scripts execute cadence/scripts/get_yield_vault_ownership.cdc "0x..."
   ```

7. **Commit Changes**
   ```bash
   git add deployments/ scripts/ cadence/scripts/ FRONTEND_INTEGRATION.md README.md
   git commit -m "feat: add frontend integration artifacts and enhanced query functions"
   git push
   ```

8. **Notify Tom**
   - Share the git submodule URL
   - Confirm contract address on testnet
   - Coordinate backend team for event indexing

---

## Summary of Files Created/Modified

### New Files
- ✅ `deployments/contract-addresses.json` - Contract addresses per network
- ✅ `deployments/artifacts/FlowYieldVaultsRequests.json` - ABI-only export
- ✅ `deployments/types/index.ts` - TypeScript type definitions
- ✅ `scripts/export-artifacts.sh` - Artifact export automation
- ✅ `cadence/scripts/get_pending_requests_for_user.cdc` - User requests query
- ✅ `cadence/scripts/get_queue_status.cdc` - Queue status query
- ✅ `cadence/scripts/get_yield_vault_ownership.cdc` - Yield Vault ownership query
- ✅ `FRONTEND_INTEGRATION.md` - Comprehensive integration guide

### Modified Files
- 🔄 `solidity/src/FlowYieldVaultsRequests.sol` - Add 4 new view functions
- 🔄 `README.md` - Add Frontend Integration section

---

## Key Coordination Points with Tom

From the November 24 call transcript:

1. **Tom needs:**
   - ✅ Contract ABIs in JSON format
   - ✅ Contract addresses via simple JSON config
   - ✅ Backend event indexing patterns
   - ✅ Clear pending request status
   - ✅ Simplified contract interface (single contract address)

2. **Critical UX requirements:**
   - Users must always know exact status of their money
   - Show queue position ("You are #3 in queue")
   - Show estimated wait time ("~45 seconds")
   - Real-time status updates
   - Clear messaging like bridge UX ("avoid bridge anxiety")

3. **Integration pattern:**
   - Git submodules (confirmed acceptable)
   - Backend already deployed (modifications only)
   - Work tracks can proceed in parallel

---

## Questions or Issues?

Contact Lionel (liobrasil) or refer to the comprehensive plan at:
`/Users/liobrasil/.claude/plans/synchronous-toasting-seahorse.md`
