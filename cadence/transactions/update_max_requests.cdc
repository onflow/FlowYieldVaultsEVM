import "FlowVaultsEVM"

/// @title Update Max Requests Per Transaction
/// @notice Updates the maximum number of requests processed per transaction
/// @dev Requires Admin resource. Recommended range: 5-50 based on gas testing.
///
/// @param newMax The new maximum requests per transaction (1-100)
///
transaction(newMax: Int) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow FlowVaultsEVM Admin resource")

        admin.updateMaxRequestsPerTx(newMax)
    }

    post {
        FlowVaultsEVM.maxRequestsPerTx == newMax: "maxRequestsPerTx was not updated correctly"
    }
}
