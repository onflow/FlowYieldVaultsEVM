// This transaction is used to trigger the FlowTransactionScheduler to execute pending scheduled transactions
// It is used in the worker tests to ensure the scheduler is working correctly.
// It is not used in the production code.
// The emulator block height needs to be advanced to trigger the scheduled transactions.

transaction { execute {} }