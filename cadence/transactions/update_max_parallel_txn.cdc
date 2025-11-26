import "FlowVaultsTransactionHandler"

/// @title Update Max Parallel Transactions
/// @notice Updates the maximum number of parallel transactions to schedule
/// @dev Requires Admin resource. Valid range: 1-10.
///
/// @param newMax New maximum parallel transaction count
///
transaction(newMax: Int) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowVaultsTransactionHandler.Admin>(
            from: FlowVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin from storage")

        admin.setMaxParallelTransactions(count: newMax)
    }

    post {
        FlowVaultsTransactionHandler.maxParallelTransactions == newMax: "Max parallel transactions was not updated correctly"
    }
}
