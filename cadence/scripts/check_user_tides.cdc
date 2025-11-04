// check_user_tides.cdc
import "TidalEVM"

/// Script to check what Tide IDs are associated with an EVM address
///
/// @param evmAddress: The EVM address (as hex string with or without 0x prefix)
/// @return Array of Tide IDs owned by this EVM user
///
access(all) fun main(evmAddress: String): [UInt64] {
    // Normalize address (remove 0x prefix if present, convert to lowercase)
    var normalizedAddress = evmAddress.toLower()
    if normalizedAddress.length > 2 && normalizedAddress.slice(from: 0, upTo: 2) == "0x" {
        normalizedAddress = normalizedAddress.slice(from: 2, upTo: normalizedAddress.length)
    }
    
    // Pad to 40 characters (20 bytes) if needed
    while normalizedAddress.length < 40 {
        normalizedAddress = "0".concat(normalizedAddress)
    }
    
    log("Checking Tides for EVM address: ".concat(normalizedAddress))
    
    let tideIds = TidalEVM.getTideIDsForEVMAddress(normalizedAddress)
    
    log("Found ".concat(tideIds.length.toString()).concat(" Tide(s)"))
    for id in tideIds {
        log("  - Tide ID: ".concat(id.toString()))
    }
    
    return tideIds
}
