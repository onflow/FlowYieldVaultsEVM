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
    // Arbitrary "from" address for dryCall (read-only).
    let fromAddress = EVM.addressFromString("0x0000000000000000000000000000000000000001")

    // Read authorizedCOA
    var authorizedCOA = ""
    let coaResult = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "authorizedCOA()",
        args: [],
        gasLimit: 100_000,
        value: 0,
        resultTypes: [Type<EVM.EVMAddress>()]
    )
    if coaResult.status == EVM.Status.successful {
        assert(coaResult.results.length == 1, message: "Invalid response from authorizedCOA()")
        authorizedCOA = (coaResult.results[0] as! EVM.EVMAddress).toString()
    }

    // Read allowlistEnabled
    var allowlistEnabled = false
    let allowlistResult = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "allowlistEnabled()",
        args: [],
        gasLimit: 100_000,
        value: 0,
        resultTypes: [Type<Bool>()]
    )
    if allowlistResult.status == EVM.Status.successful {
        assert(allowlistResult.results.length == 1, message: "Invalid response from allowlistEnabled()")
        allowlistEnabled = allowlistResult.results[0] as! Bool
    }

    // Read blocklistEnabled
    var blocklistEnabled = false
    let blocklistResult = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "blocklistEnabled()",
        args: [],
        gasLimit: 100_000,
        value: 0,
        resultTypes: [Type<Bool>()]
    )
    if blocklistResult.status == EVM.Status.successful {
        assert(blocklistResult.results.length == 1, message: "Invalid response from blocklistEnabled()")
        blocklistEnabled = blocklistResult.results[0] as! Bool
    }

    // Read maxPendingRequestsPerUser
    var maxPendingRequestsPerUser: UInt256 = 0
    let maxResult = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "maxPendingRequestsPerUser()",
        args: [],
        gasLimit: 100_000,
        value: 0,
        resultTypes: [Type<UInt256>()]
    )
    if maxResult.status == EVM.Status.successful {
        assert(maxResult.results.length == 1, message: "Invalid response from maxPendingRequestsPerUser()")
        maxPendingRequestsPerUser = maxResult.results[0] as! UInt256
    }

    // Read getPendingRequestCount
    var pendingRequestCount: UInt256 = 0
    let countResult = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "getPendingRequestCount()",
        args: [],
        gasLimit: 100_000,
        value: 0,
        resultTypes: [Type<UInt256>()]
    )
    if countResult.status == EVM.Status.successful {
        assert(countResult.results.length == 1, message: "Invalid response from getPendingRequestCount()")
        pendingRequestCount = countResult.results[0] as! UInt256
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
