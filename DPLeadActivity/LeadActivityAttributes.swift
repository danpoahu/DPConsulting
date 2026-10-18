//
//  LeadActivityAttributes.swift
//  DPLeadActivity
//
//  The "new web lead" Live Activity. The website worker (dp-cloudkit-proxy, src/apns.ts)
//  starts it with a push-to-start notification whose JSON must match ContentState.
//  ⚠ Keep in step with the copy in DPconsult/LeadActivityAttributes.swift: ActivityKit
//  matches the two by type name and Codable shape.
//

import ActivityKit
import Foundation

struct LeadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "quote" or "prospect"
        var kind: String
        /// Client, e.g. "Leilani K., Aloha Bakery"
        var title: String
        /// Project title or business
        var detail: String
        /// Unix seconds
        var receivedAt: Double
    }
}
