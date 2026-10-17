//
//  QuoteDraftSeedTests.swift
//  DPconsultTests
//
//  The Quote button reads hours back out of a web quote request's notes, so the
//  quote's money depends on this parser.
//

import Testing
@testable import DPconsult

@MainActor
struct QuoteDraftSeedTests {

    static let notes = """
    WEB QUOTE REQUEST · Oct 17, 2026 at 12:16 PM · ref 8F8CE450
    Malasada pre-order app for Test Bakery
    Proposal for Leilani, Test Bakery

    SCOPE AND ESTIMATE (hours)
    • Planning, screen design and clickable prototype: 12 h
    • iPhone app screens: menu, cart, checkout (about 7 screens): 28 h
    • Android app in Kotlin: 36 h (not in Starter)
    Subtotal: 76 h · contingency for unknowns: 16 h · total 92 h at $55/h

    OPTIONS (prices plus Hawaii GET 4.712%)
    Recommended: $5,060 + GET $238.43 = $5,298.43  (92 h)

    TERMS
    • Two rounds of changes are included; more is billed at $60/h plus GET.
    """

    @Test func readsLineItemsContingencyAndRate() throws {
        let seed = try #require(QuoteDraftSeed.parse(Self.notes))
        #expect(seed.title == "Malasada pre-order app for Test Bakery")
        #expect(seed.items.map(\.hours) == [12, 28, 36, 16])
        #expect(seed.items[1].description == "iPhone app screens: menu, cart, checkout (about 7 screens)")
        #expect(seed.items.last?.description == "Contingency for unknowns")
        #expect(seed.items.allSatisfy { $0.rate == 55 }) // the scope rate, not the terms line
        #expect(seed.addsGET)
    }

    @Test func invoiceTotalMatchesTheProposal() throws {
        let items = try #require(QuoteDraftSeed.parse(Self.notes)).invoiceItems
        #expect(items.count == 5)
        #expect(items.last?.description == "Hawaii GET 4.712%")
        #expect(items.last?.amount == 238.43)
        #expect(abs(items.reduce(0) { $0 + $1.amount } - 5298.43) < 0.001)
    }

    @Test func followsHoursDanEditedInTheNotes() throws {
        let edited = Self.notes.replacingOccurrences(of: "Android app in Kotlin: 36 h", with: "Android app in Kotlin: 30 h")
        let seed = try #require(QuoteDraftSeed.parse(edited))
        #expect(seed.items.map(\.hours) == [12, 28, 30, 16])
    }

    @Test func usesOnlyTheNewestRequest() throws {
        let older = Self.notes.replacingOccurrences(of: "12 h", with: "99 h")
        let both = Self.notes + "\n\n" + QuoteRequestService.divider + "\n\n" + older
        #expect(try #require(QuoteDraftSeed.parse(both)).items.first?.hours == 12)
    }

    @Test func ignoresOrdinaryNotes() {
        #expect(QuoteDraftSeed.parse("Business: Anchor Church\nCall after 3pm") == nil)
        #expect(QuoteDraftSeed.parse("") == nil)
    }
}
