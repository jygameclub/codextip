import Foundation

/// Offline price snapshot. Values are USD per million tokens, not subscription charges.
/// Sources and exclusions are documented in docs/PRICING.md.
public struct ModelTokenPrice {
    public let input: Double
    public let cached: Double
    public let cacheWrite: Double?
    public let output: Double
    public let longContext: Bool
    public let sessionLongContext: Bool
}

public struct TokenCostEstimate {
    public init() {}
    public var inputUSD = 0.0
    public var cachedUSD = 0.0
    public var cacheWriteUSD = 0.0
    public var outputUSD = 0.0
    public var pricedTokens: Int64 = 0
    public var unpricedTokens: Int64 = 0
    public var unpricedModels = Set<String>()
    public var knownUSD: Double { inputUSD + cachedUSD + cacheWriteUSD + outputUSD }
    public var isPartial: Bool { unpricedTokens > 0 }
    public var display: String {
        guard pricedTokens > 0 || unpricedTokens == 0 else { return L10n.text("价格未知", "Price unknown") }
        let amount = usd(knownUSD)
        return isPartial ? L10n.text("已知部分 ≈\(amount)", "Known part ≈\(amount)") : "≈\(amount)"
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        var value = Self()
        value.inputUSD = lhs.inputUSD + rhs.inputUSD
        value.cachedUSD = lhs.cachedUSD + rhs.cachedUSD
        value.cacheWriteUSD = lhs.cacheWriteUSD + rhs.cacheWriteUSD
        value.outputUSD = lhs.outputUSD + rhs.outputUSD
        value.pricedTokens = lhs.pricedTokens + rhs.pricedTokens
        value.unpricedTokens = lhs.unpricedTokens + rhs.unpricedTokens
        value.unpricedModels = lhs.unpricedModels.union(rhs.unpricedModels)
        return value
    }
}

public enum TokenPricing {
    public static let checkedOn = "2026-09-06"
    public static let sourceURL = URL(string: "https://developers.openai.com/api/docs/pricing")!
    // Exact model matching: never charge Spark, Pro, or an unknown variant at another model's rate.
    private static let prices: [String: ModelTokenPrice] = {
        func rate(_ input: Double, _ cached: Double, _ output: Double, write: Double? = nil,
                  long: Bool = false, session: Bool = false) -> ModelTokenPrice {
            ModelTokenPrice(input: input, cached: cached, cacheWrite: write, output: output, longContext: long, sessionLongContext: session)
        }
        return [
            "gpt-6-astra": rate(10, 1, 50, write: 12.5, long: true),
            "gpt-5.6-sol": rate(4, 0.4, 20, write: 5, long: true),
            "gpt-5.6": rate(4, 0.4, 20, write: 5, long: true),
            "gpt-5.6-terra": rate(2, 0.2, 12, write: 2.5, long: true),
            "gpt-5.6-luna": rate(0.2, 0.02, 1.2, write: 0.25, long: true),
            "gpt-5.5": rate(5, 0.5, 30, long: true, session: true),
            "gpt-5.4": rate(2.5, 0.25, 15, long: true, session: true),
            "gpt-5.4-mini": rate(0.75, 0.075, 4.5),
            "gpt-5.3-codex": rate(1.75, 0.175, 14),
            "gpt-5.2-codex": rate(1.75, 0.175, 14),
            "gpt-5.1-codex-max": rate(1.25, 0.125, 10),
            "gpt-5-codex": rate(1.25, 0.125, 10)
        ]
    }()
    public static func price(for model: String) -> ModelTokenPrice? { prices[model] }

    public static func estimate(model: String, counts: TokenCounts, sessionIsLong: Bool = false) -> TokenCostEstimate {
        var result = TokenCostEstimate()
        guard let price = price(for: model), counts.cacheWrite == 0 || price.cacheWrite != nil else {
            result.unpricedTokens = counts.total
            if counts.total > 0 { result.unpricedModels.insert(model) }
            return result
        }
        let long = price.longContext && (counts.input > 272_000 || (price.sessionLongContext && sessionIsLong))
        let inputMultiplier = long ? 2.0 : 1.0
        let outputMultiplier = long ? 1.5 : 1.0
        // Cache reads/writes are subsets of input. Reasoning is already part of output.
        result.inputUSD = Double(max(0, counts.uncached - counts.cacheWrite)) * price.input * inputMultiplier / 1e6
        result.cachedUSD = Double(counts.cached) * price.cached * inputMultiplier / 1e6
        result.cacheWriteUSD = Double(counts.cacheWrite) * (price.cacheWrite ?? 0) * inputMultiplier / 1e6
        result.outputUSD = Double(counts.output) * price.output * outputMultiplier / 1e6
        result.pricedTokens = counts.total
        return result
    }
}

public func usd(_ amount: Double) -> String {
    if amount > 0 && amount < 0.01 { return "<$0.01" }
    return amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
}
