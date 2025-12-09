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
  yieldVaultId: string;          // uint64 as string (NO_YIELD_VAULT_ID = type(uint64).max)
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

export interface YieldVaultCreatedForEVMUserEvent {
  evmAddress: string;
  yieldVaultId: string;
  amount: string;
}

export interface YieldVaultDepositedForEVMUserEvent {
  evmAddress: string;
  yieldVaultId: string;
  amount: string;
  isYieldVaultOwner: boolean;
}

export interface YieldVaultWithdrawnForEVMUserEvent {
  evmAddress: string;
  yieldVaultId: string;
  amount: string;
}

export interface YieldVaultClosedForEVMUserEvent {
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
  YieldVaultCreatedForEVMUserEvent,
  YieldVaultDepositedForEVMUserEvent,
  YieldVaultWithdrawnForEVMUserEvent,
  YieldVaultClosedForEVMUserEvent,
  ContractAddresses,
  NetworkMetadata,
  DeploymentManifest,
};
