import "FlowYieldVaultsTransactionHandler"

/// @title Stop All Scheduled Transactions
/// @notice Stops and cancels all scheduled transactions, pausing the handler and refunding fees
/// @dev This will:
///      1. Pause the handler to prevent new scheduling
///      2. Cancel all pending scheduled transactions
///      3. Refund fees to the contract account
///      Requires Admin resource.
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsTransactionHandler.Admin>(
            from: FlowYieldVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        let result = admin.stopAll()

        log("Stopped all scheduled transactions")
        log("Cancelled IDs: ".concat((result["cancelledIds"]! as! [UInt64]).length.toString()))
        log("Total refunded: ".concat((result["totalRefunded"]! as! UFix64).toString()))
    }
}
