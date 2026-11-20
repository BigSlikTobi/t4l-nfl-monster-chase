import Foundation
@testable import CardScoutCore

extension CardAnalysis {
    mutating func setFixtureScoutValue(_ cents: Int, currency: String = "EUR", shipping: String = "unknown",
                                       asOf: Date, validFor: TimeInterval = 3600) {
        if insights == nil {
            insights = CardInsights(rarityTier: "base", rarityBullets: [], conditionStatus: "unknown",
                conditionIssues: [], conditionLimitations: [], marketBullets: [], marketReferences: [],
                sourceChecks: [], actionReason: "")
        }
        insights?.scoutEstimate = CardScoutValue(amountCents: cents, currency: currency, shipping: shipping,
            checkedAt: marketCheckedAt, expiresAt: asOf.addingTimeInterval(validFor).timeIntervalSince1970)
    }
}
