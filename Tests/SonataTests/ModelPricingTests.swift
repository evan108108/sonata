import XCTest
@testable import Sonata

// The token-usage card prices an unknown model through `defaultModel`. A model
// the fleet actually runs must have its own row, or its cost is silently the
// default's. (2026-11-10: the fleet ran claude-opus-5-5, absent from the map,
// so the card priced it as claude-opus-4-7 at $5/$25 instead of $4/$20.)
final class ModelPricingTests: XCTestCase {

    /// 80/20 input/output blend, per million tokens — mirrors blendedCostUSD.
    private func blendedPerMTok(_ p: ModelPricing.Price) -> Double {
        p.input * 0.8 + p.output * 0.2
    }

    func testOpus55ResolvesToItsOwnRowNotTheDefault() throws {
        let own = try XCTUnwrap(ModelPricing.prices["claude-opus-5-5"], "claude-opus-5-5 needs its own row")
        let fallback = try XCTUnwrap(ModelPricing.prices[ModelPricing.defaultModel])
        XCTAssertEqual(own.input, 4.0)
        XCTAssertEqual(own.output, 20.0)

        let cost = ModelPricing.blendedCostUSD(model: "claude-opus-5-5", totalTokens: 1_000_000)
        XCTAssertEqual(cost, blendedPerMTok(own), accuracy: 1e-9)
        XCTAssertNotEqual(cost, blendedPerMTok(fallback), accuracy: 1e-9,
                          "claude-opus-5-5 is being priced through defaultModel")
    }

    func testCurrentLineupHasOwnRows() {
        for id in ["claude-fable-5-2", "claude-mythos-5-2", "claude-opus-5-5",
                   "claude-sonnet-5-5", "claude-haiku-5-5"] {
            XCTAssertNotNil(ModelPricing.prices[id], "\(id) missing from ModelPricing.prices")
        }
    }

    func testUnknownModelFallsBackToDefault() throws {
        let fallback = try XCTUnwrap(ModelPricing.prices[ModelPricing.defaultModel])
        let cost = ModelPricing.blendedCostUSD(model: "claude-not-a-model", totalTokens: 1_000_000)
        XCTAssertEqual(cost, blendedPerMTok(fallback), accuracy: 1e-9)
    }
}
