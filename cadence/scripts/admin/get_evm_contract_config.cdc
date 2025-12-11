import "FlowYieldVaultsEVM"
import "EVM"

/// @title Get EVM Contract Config
/// @notice Reads the main configuration values from the EVM FlowYieldVaultsRequests contract
/// @dev Calls multiple view functions to gather contract state
///
/// @param contractAddress The FlowYieldVaultsRequests contract address
/// @return A struct containing contract configuration
///
access(all) struct EVMContractConfig {
    access(all) let contractAddress: String
    access(all) let authorizedCOA: String
    access(all) let allowlistEnabled: Bool
    access(all) let blocklistEnabled: Bool
    access(all) let maxPendingRequestsPerUser: UInt256
    access(all) let pendingRequestCount: UInt256

    init(
        contractAddress: String,
        authorizedCOA: String,
        allowlistEnabled: Bool,
        blocklistEnabled: Bool,
        maxPendingRequestsPerUser: UInt256,
        pendingRequestCount: UInt256
    ) {
        self.contractAddress = contractAddress
        self.authorizedCOA = authorizedCOA
        self.allowlistEnabled = allowlistEnabled
        self.blocklistEnabled = blocklistEnabled
        self.maxPendingRequestsPerUser = maxPendingRequestsPerUser
        self.pendingRequestCount = pendingRequestCount
    }
}

access(all) fun main(contractAddress: String): EVMContractConfig {
    let evmContractAddress = EVM.addressFromString(contractAddress)

    // Read authorizedCOA
    var authorizedCOA = ""
    let coaCalldata = EVM.encodeABIWithSignature("authorizedCOA()", [])
    let coaResult = evmContractAddress.call(
        data: coaCalldata,
        gasLimit: 100_000,
        value: EVM.Balance(attoflow: 0)
    )
    if coaResult.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<EVM.EVMAddress>()], data: coaResult.data)
        authorizedCOA = (decoded[0] as! EVM.EVMAddress).toString()
    }

    // Read allowlistEnabled
    var allowlistEnabled = false
    let allowlistCalldata = EVM.encodeABIWithSignature("allowlistEnabled()", [])
    let allowlistResult = evmContractAddress.call(
        data: allowlistCalldata,
        gasLimit: 100_000,
        value: EVM.Balance(attoflow: 0)
    )
    if allowlistResult.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<Bool>()], data: allowlistResult.data)
        allowlistEnabled = decoded[0] as! Bool
    }

    // Read blocklistEnabled
    var blocklistEnabled = false
    let blocklistCalldata = EVM.encodeABIWithSignature("blocklistEnabled()", [])
    let blocklistResult = evmContractAddress.call(
        data: blocklistCalldata,
        gasLimit: 100_000,
        value: EVM.Balance(attoflow: 0)
    )
    if blocklistResult.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<Bool>()], data: blocklistResult.data)
        blocklistEnabled = decoded[0] as! Bool
    }

    // Read maxPendingRequestsPerUser
    var maxPendingRequestsPerUser: UInt256 = 0
    let maxCalldata = EVM.encodeABIWithSignature("maxPendingRequestsPerUser()", [])
    let maxResult = evmContractAddress.call(
        data: maxCalldata,
        gasLimit: 100_000,
        value: EVM.Balance(attoflow: 0)
    )
    if maxResult.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: maxResult.data)
        maxPendingRequestsPerUser = decoded[0] as! UInt256
    }

    // Read getPendingRequestCount
    var pendingRequestCount: UInt256 = 0
    let countCalldata = EVM.encodeABIWithSignature("getPendingRequestCount()", [])
    let countResult = evmContractAddress.call(
        data: countCalldata,
        gasLimit: 100_000,
        value: EVM.Balance(attoflow: 0)
    )
    if countResult.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: countResult.data)
        pendingRequestCount = decoded[0] as! UInt256
    }

    return EVMContractConfig(
        contractAddress: contractAddress,
        authorizedCOA: authorizedCOA,
        allowlistEnabled: allowlistEnabled,
        blocklistEnabled: blocklistEnabled,
        maxPendingRequestsPerUser: maxPendingRequestsPerUser,
        pendingRequestCount: pendingRequestCount
    )
}
