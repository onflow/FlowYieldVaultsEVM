import "FlowYieldVaultsEVM"

/// @title Cancel Request
/// @notice Cancels a pending request on the EVM contract
/// @dev Requires Worker resource. The Worker's COA must be the owner of the Solidity contract.
///      Can be used by admin to cancel any user's pending request.
///      Refunds escrowed funds for CREATE_YIELDVAULT and DEPOSIT_TO_YIELDVAULT requests.
///
/// @param requestId The request ID to cancel
///
transaction(requestId: UInt256) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow FlowYieldVaultsEVM Worker resource")

        worker.cancelRequest(requestId)
    }
}
