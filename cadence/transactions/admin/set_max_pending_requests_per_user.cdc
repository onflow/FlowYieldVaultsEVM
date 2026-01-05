import "FlowYieldVaultsEVM"

/// @title Set Max Pending Requests Per User
/// @notice Sets the maximum number of pending requests allowed per user on the EVM contract
/// @dev Requires Worker resource. The Worker's COA must be the owner of the Solidity contract.
///
/// @param maxRequests The new maximum pending requests per user (0 = unlimited)
///
transaction(maxRequests: UInt256) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow FlowYieldVaultsEVM Worker resource")

        worker.setMaxPendingRequestsPerUser(maxRequests)
    }
}
