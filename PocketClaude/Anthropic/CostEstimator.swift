import Foundation

/// Rough session-cost estimate from the `usage` block the API returns.
///
/// These are public list prices in USD per million tokens, captured 2026-08.
/// They are an estimate for your own awareness — the invoice is the source of
/// truth. See DECISIONS.md for why we track this client-side.
enum CostEstimator {
    struct Rate: Equatable, Sendable {
        var inputPerMTok: Double
        var outputPerMTok: Double

        /// Cache writes cost ~1.25x base input; cache reads ~0.1x.
        var cacheWritePerMTok: Double { inputPerMTok * 1.25 }
        var cacheReadPerMTok: Double { inputPerMTok * 0.10 }
    }

    static let rates: [String: Rate] = [
        "claude-opus-5": Rate(inputPerMTok: 5.00, outputPerMTok: 25.00),
        "claude-sonnet-5": Rate(inputPerMTok: 3.00, outputPerMTok: 15.00),
        "claude-haiku-4-5": Rate(inputPerMTok: 1.00, outputPerMTok: 5.00),
    ]

    /// Unknown models fall back to Opus pricing so the estimate is never a
    /// pleasant surprise.
    static func rate(for model: String) -> Rate {
        rates[model] ?? rates["claude-opus-5"]!
    }

    static func cost(of usage: TokenUsage, model: String) -> Double {
        let rate = rate(for: model)
        let million = 1_000_000.0
        return Double(usage.inputTokens) / million * rate.inputPerMTok
            + Double(usage.outputTokens) / million * rate.outputPerMTok
            + Double(usage.cacheCreationInputTokens) / million * rate.cacheWritePerMTok
            + Double(usage.cacheReadInputTokens) / million * rate.cacheReadPerMTok
    }

    static func format(_ cost: Double) -> String {
        if cost < 0.01 && cost > 0 { return "<$0.01" }
        return String(format: "$%.2f", cost)
    }
}
