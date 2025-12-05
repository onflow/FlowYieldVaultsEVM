import "FlowYieldVaultsTransactionHandler"

/// @title Update Max Parallel Transactions
/// @notice Updates the maximum number of parallel transactions to schedule
/// @dev Requires Admin resource. Valid range: 1-10.
///
/// @param newMax New maximum parallel transaction count
///
transaction(newMax: Int) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsTransactionHandler.Admin>(
            from: FlowYieldVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin from storage")

        admin.setMaxParallelTransactions(count: newMax)
    }

    post {
        FlowYieldVaultsTransactionHandler.maxParallelTransactions == newMax: "Max parallel transactions was not updated correctly"
    }
}
