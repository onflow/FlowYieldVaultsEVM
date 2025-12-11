import "FlowYieldVaultsEVM"
import "EVM"

/// @title Set Authorized COA
/// @notice Sets the authorized COA address on the EVM FlowYieldVaultsRequests contract
/// @dev Requires Worker resource. The Worker's COA must be the owner of the Solidity contract.
///      The new COA will be authorized to call startProcessing and completeProcessing.
///
/// @param coa The EVM address of the new authorized COA
///
transaction(coa: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow FlowYieldVaultsEVM Worker resource")

        let evmCOA = EVM.addressFromString(coa)

        worker.setAuthorizedCOA(evmCOA)
    }
}
