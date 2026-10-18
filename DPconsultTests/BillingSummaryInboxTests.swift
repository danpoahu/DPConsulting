//
//  BillingSummaryInboxTests.swift
//  DPconsultTests
//
//  Work summaries Claude drops in the Reports folder badge Invoicing; old ones must not.
//

import Foundation
import Testing
@testable import DPconsult

struct BillingSummaryInboxTests {
    let folder: URL
    let defaults: UserDefaults
    let suite = "BillingSummaryInboxTests-\(UUID().uuidString)"

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private func write(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try "<html></html>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func existingSummariesAreBaselinedNotBadged() throws {
        _ = try write("LDAH-September-2026-billing-summary.html")
        #expect(BillingSummaryInbox.pending(in: folder, defaults: defaults).isEmpty)
        #expect(BillingSummaryInbox.pending(in: folder, defaults: defaults).isEmpty)
    }

    @Test func newSummaryShowsUntilHandled() throws {
        _ = BillingSummaryInbox.pending(in: folder, defaults: defaults) // baseline (empty folder)
        let october = try write("LDAH-October-2026-billing-summary.html")
        _ = try write("Session-Report-2026-10-17.html") // not a billing summary
        // Compare names: the temp folder resolves as /var or /private/var depending on the call.
        #expect(BillingSummaryInbox.pending(in: folder, defaults: defaults).map(\.lastPathComponent) == [october.lastPathComponent])

        BillingSummaryInbox.markHandled(october, defaults: defaults)
        #expect(BillingSummaryInbox.pending(in: folder, defaults: defaults).isEmpty)
    }

    @Test func displayNameReadsLikeAMonth() {
        let url = URL(fileURLWithPath: "/x/LDAH-October-2026-billing-summary.html")
        #expect(BillingSummaryInbox.displayName(url) == "LDAH October 2026")
    }
}
