import "FlowVaultsEVM"

/// Get the current MAX_REQUESTS_PER_TX value and related statistics
/// 
/// This helps you understand current batch processing configuration
/// and make informed decisions about tuning
///
access(all) fun main(): {String: AnyStruct} {
    let maxRequestsPerTx = FlowVaultsEVM.MAX_REQUESTS_PER_TX
    
    // Calculate some helpful metrics
    let executionsPerHourAt5s = 720
    let executionsPerHourAt60s = 60
    
    let maxThroughputPerHour5s = maxRequestsPerTx * executionsPerHourAt5s
    let maxThroughputPerHour60s = maxRequestsPerTx * executionsPerHourAt60s
    
    return {
        "currentMaxRequestsPerTx": maxRequestsPerTx,
        "maxThroughputPerHour": {
            "at5sDelay": maxThroughputPerHour5s,
            "at60sDelay": maxThroughputPerHour60s
        },
        "estimatedGasPerExecution": {
            "description": "Varies based on request complexity",
            "rangePerRequest": "~100k-500k gas",
            "totalRange": calculateGasRange(maxRequestsPerTx)
        },
        "recommendations": getRecommendations(maxRequestsPerTx)
    }
}

access(all) fun calculateGasRange(_ batchSize: Int): String {
    let lowGas = batchSize * 100_000
    let highGas = batchSize * 500_000
    return lowGas.toString().concat(" - ").concat(highGas.toString()).concat(" gas")
}

access(all) fun getRecommendations(_ current: Int): [String] {
    let recommendations: [String] = []
    
    if current < 5 {
        recommendations.append("⚠️  Very small batch size - consider increasing for efficiency")
    } else if current < 10 {
        recommendations.append("✅ Conservative batch size - good for testing")
    } else if current <= 30 {
        recommendations.append("✅ Optimal batch size range")
    } else if current <= 50 {
        recommendations.append("⚠️  Large batch size - monitor for gas issues")
    } else {
        recommendations.append("🚨 Very large batch size - high risk of gas limits")
    }
    
    return recommendations
}
