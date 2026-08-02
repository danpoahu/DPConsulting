//
//  BillingSummaryParserTests.swift
//  DPconsultTests
//
//  Pure tests for the billing-summary importer. No SwiftData, no UI, no file system.
//  Fixtures are trimmed from the real LDAH July 2026 and June 2026 summaries.
//

import Testing
@testable import DPconsult

struct BillingSummaryParserTests {

    // MARK: - Fixtures

    /// Trimmed from LDAH-July-2026-billing-summary.html, markup preserved verbatim.
    let julyHTML = """
    <h1>LDAH — July 2026 Work Summary</h1>

    <h2>Major deliverables</h2>
    <table>
    <tr><th>Date</th><th>Deliverable</th><th>Products</th></tr>
    <tr><td class="d">7-06 → 7-07</td>
    <td><b>Paid memberships went live</b> — PayPal Smart Buttons taking real charges.</td>
    <td><span class="tag t-web">Web</span></td></tr>

    <tr><td class="d">7-09 → 7-14</td>
    <td><b>Connect-Gen Parent Report Worksheet</b>, three phases — parent web form.</td>
    <td><span class="tag t-web">Web</span></td></tr>

    <tr><td class="d">7-13 → 7-14</td>
    <td><b>Dashboard release run</b> — Training Videos search-first list.</td>
    <td><span class="tag t-int">Dash</span></td></tr>

    <tr><td class="d">7-16 → 7-18</td>
    <td><b>Member portal built</b> — login, profile, event signups.</td>
    <td><span class="tag t-web">Web</span></td></tr>

    <tr><td class="d">7-19 → 7-20</td>
    <td><b>Multi-recipient contact emails</b> (two addresses per contact).</td>
    <td><span class="tag t-cf">CF</span></td></tr>

    <tr><td class="d">7-21</td>
    <td><b>Google Play production access</b> secured for all three apps.</td>
    <td><span class="tag t-app">App</span></td></tr>

    <tr><td class="d">7-24</td>
    <td><b>Events system rebuilt</b>, three phases — four tabs replaced by one list.</td>
    <td><span class="tag t-int">Dash</span></td></tr>

    <tr><td class="d">7-25 → 7-27</td>
    <td><b>Second parent on contacts</b> (both parents receive every family email).</td>
    <td><span class="tag t-int">Dash</span></td></tr>

    <tr><td class="d">7-29</td>
    <td><b>Member portal went live</b> at ldahawaii.org/Members/.</td>
    <td><span class="tag t-web">Web</span></td></tr>

    <tr><td class="d">7-30 → 7-31</td>
    <td><b>First real members through the portal.</b> Login instructions automated.</td>
    <td><span class="tag t-web">Web</span></td></tr>
    </table>

    <h2>Hours by week</h2>
    <table>
    <tr><th>Week</th><th>Focus</th><th class="c">Commits</th><th class="h">Hours</th></tr>
    <tr><td class="d">Jul 1 – 5</td><td>Membership build-up, PayPal integration, announcement tokens</td><td class="c">21</td><td class="h">5.1</td></tr>
    <tr><td class="d">Jul 6 – 12</td><td>Memberships live; Connect-Gen worksheet phases 1–3; flyer→event AI</td><td class="c">58</td><td class="h">18.8</td></tr>
    <tr><td class="d">Jul 13 – 19</td><td>Dashboard release run; member portal built; screening consent</td><td class="c">105</td><td class="h">22.9</td></tr>
    <tr><td class="d">Jul 20 – 26</td><td>Google Play; recordings archive; Events rebuilt; second parent</td><td class="c">107</td><td class="h">24.2</td></tr>
    <tr><td class="d">Jul 27 – 31</td><td>Home redesign; PTI export; portal live; first members; data quality</td><td class="c">100</td><td class="h">19.0</td></tr>
    <tr class="tot"><td></td><td>July 2026 total</td><td class="c">391</td><td class="h">90.0&nbsp;h</td></tr>
    </table>

    <h2>For the invoice</h2>
    <table>
    <tr><td style="width:60%"><b>July 2026 — LDAH development</b><br>
    <span style="color:var(--soft);font-size:12px;">Staff dashboard, public website, mobile app and Cloud Functions.
    28 working days, 391 commits, 14 session reports.</span></td>
    <td class="h"><span class="big">90.0</span><br><span>HOURS</span></td></tr>
    </table>
    """

    /// A summary with the hours table but no deliverables and no invoice block,
    /// matching the shape of the June 2026 file.
    let bareHTML = """
    <h1>LDAH — June 2026 Work Summary</h1>
    <h2>Hours by week</h2>
    <table>
    <tr><th>Week</th><th>Focus</th><th class="c">Commits</th><th class="h">Hours</th></tr>
    <tr><td class="d">~Jun 2 – 8</td><td>Session sheet sort</td><td class="c">10</td><td class="h">4.5</td></tr>
    </table>
    """

    // MARK: - Hours table

    @Test func parsesFiveWeeksAndStatedTotal() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        #expect(summary.weeks.count == 5)
        #expect(summary.statedTotalHours == 90.0)
        #expect(summary.weeks.first?.label == "Jul 1 – 5")
        let sum = summary.weeks.reduce(0) { $0 + $1.hours }
        #expect(abs(sum - 90.0) < 0.0001)
    }

    @Test func keepsArrowsAndEnDashesInFocusText() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        #expect(summary.weeks[1].focus == "Memberships live; Connect-Gen worksheet phases 1–3; flyer→event AI")
    }

    @Test func totalRowIsExcludedFromWeeks() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        #expect(!summary.weeks.contains { $0.label.contains("total") })
        #expect(!summary.weeks.contains { $0.focus.contains("July 2026 total") })
    }

    @Test func parsesHoursWithTrailingEntityAndUnit() {
        #expect(BillingHTML.number(in: BillingHTML.clean("90.0&nbsp;h")) == 90.0)
    }

    @Test func capturesTitleFromH1() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        #expect(summary.title == "LDAH — July 2026 Work Summary")
    }

    @Test func commitsAreParsed() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        #expect(summary.weeks.map(\.commits) == [21, 58, 105, 107, 100])
    }

    // MARK: - Errors

    @Test func missingHoursTableThrowsNoTable() {
        #expect(throws: BillingSummaryParseError.noTable) {
            try BillingSummaryParser.parse("<h1>Nothing here</h1><p>no table</p>")
        }
    }

    @Test func headerOnlyTableThrowsNoRows() {
        let html = """
        <h2>Hours by week</h2>
        <table><tr><th>Week</th><th>Focus</th><th>Commits</th><th>Hours</th></tr></table>
        """
        #expect(throws: BillingSummaryParseError.noRows) {
            try BillingSummaryParser.parse(html)
        }
    }

    // MARK: - Week day ranges

    @Test func parsesWeekDayRanges() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        let first = summary.weeks[0]
        #expect(first.month == 7)
        #expect(first.startDay == 1)
        #expect(first.endDay == 5)

        let last = summary.weeks[4]
        #expect(last.startDay == 27)
        #expect(last.endDay == 31)
    }

    @Test func monthNameMapsToNumber() {
        #expect(BillingHTML.monthNumber(inLabel: "Jul 1 – 5") == 7)
        #expect(BillingHTML.monthNumber(inLabel: "Jun 2 – 8") == 6)
        #expect(BillingHTML.monthNumber(inLabel: "1 – 5") == 0)
    }

    // MARK: - Deliverables

    @Test func parsesDeliverableDateForms() {
        let single = BillingHTML.integers(in: "7-24")
        #expect(single == [7, 24])

        let range = BillingHTML.integers(in: "7-25 → 7-27")
        #expect(range == [7, 25, 7, 27])

        let approx = BillingHTML.integers(in: "6-25".replacingOccurrences(of: "~", with: ""))
        #expect(approx == [6, 25])
    }

    @Test func parsesAllDeliverableRows() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        #expect(summary.deliverables.count == 10)
        #expect(summary.deliverables.first?.month == 7)
        #expect(summary.deliverables.first?.startDay == 6)
        #expect(summary.deliverables.first?.endDay == 7)
        #expect(summary.deliverables.first?.text.hasPrefix("Paid memberships went live") == true)
    }

    @Test func firstWeekCollectsNoDeliverables() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        #expect(summary.weeks[0].notes.isEmpty)
    }

    @Test func secondWeekCollectsTwoDeliverables() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        let notes = summary.weeks[1].notes
        #expect(notes.contains("Paid memberships went live"))
        #expect(notes.contains("Connect-Gen Parent Report Worksheet"))
        #expect(notes.contains(" · "))
    }

    @Test func lastWeekCollectsThreeDeliverables() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        let notes = summary.weeks[4].notes
        #expect(notes.contains("Second parent on contacts"))
        #expect(notes.contains("Member portal went live"))
        #expect(notes.contains("First real members through the portal"))
    }

    @Test func deliverableSpanningAWeekBoundaryAppearsInBothWeeks() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        // 7-19 → 7-20 straddles "Jul 13 – 19" and "Jul 20 – 26"
        #expect(summary.weeks[2].notes.contains("Multi-recipient contact emails"))
        #expect(summary.weeks[3].notes.contains("Multi-recipient contact emails"))
    }

    @Test func boldMarkupIsStrippedFromDeliverableText() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        #expect(!summary.deliverables.contains { $0.text.contains("<b>") })
    }

    @Test func missingDeliverablesTableIsNotAnError() throws {
        let summary = try BillingSummaryParser.parse(bareHTML)
        #expect(summary.deliverables.isEmpty)
        #expect(summary.weeks.count == 1)
        #expect(summary.weeks[0].notes.isEmpty)
    }

    // MARK: - For the invoice block

    @Test func invoiceBlurbFlattensLineBreak() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        let blurb = try #require(summary.invoiceBlurb)
        #expect(blurb.hasPrefix("July 2026 — LDAH development — Staff dashboard"))
        #expect(blurb.hasSuffix("14 session reports."))
    }

    @Test func missingInvoiceBlurbIsNil() throws {
        let summary = try BillingSummaryParser.parse(bareHTML)
        #expect(summary.invoiceBlurb == nil)
    }

    // MARK: - Totals and discount

    @Test func discountLandsOnTheTargetTotal() throws {
        var summary = try BillingSummaryParser.parse(julyHTML)
        // Bill the Aug-1 session to July: last week 19.0 → 22.75
        summary.weeks[4].hours = 22.75

        let totals = BillingSummaryParser.totals(weeks: summary.weeks, rate: 50, target: 1150)
        #expect(totals.grossHours == 93.75)
        #expect(totals.grossAmount == 4687.50)
        #expect(totals.discount == 3537.50)
        #expect(totals.total == 1150.00)
    }

    @Test func noDiscountWhenTargetEqualsGross() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        let totals = BillingSummaryParser.totals(weeks: summary.weeks, rate: 50, target: 4500)
        #expect(totals.grossAmount == 4500.00)
        #expect(totals.discount == 0)
        #expect(totals.total == 4500.00)
    }

    @Test func noDiscountWhenTargetIsAbsent() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        let totals = BillingSummaryParser.totals(weeks: summary.weeks, rate: 50, target: nil)
        #expect(totals.discount == 0)
        #expect(totals.total == 4500.00)
    }

    // MARK: - Customer matching

    @Test func acronymFromCustomerName() {
        #expect(BillingCustomerMatch.acronym(for: "Leadership in Disabilities & Achievement of Hawai'i") == "LDAH")
        #expect(BillingCustomerMatch.acronym(for: "Marie Borders") == "MB")
        #expect(BillingCustomerMatch.acronym(for: "Vanto Services Group") == "VSG")
    }

    @Test func matchesLDAHAndNotOtherCustomers() {
        let haystack = "LDAH — July 2026 Work Summary LDAH-July-2026-billing-summary.html"
        let names = ["Anchor Church", "Dan Pellegrini", "Daniel O'Sullivan",
                     "Leadership in Disabilities & Achievement of Hawai'i",
                     "Marie Borders", "Ron Whitney", "Vanto Services Group"]

        #expect(BillingCustomerMatch.best(in: names, haystack: haystack)
                == "Leadership in Disabilities & Achievement of Hawai'i")
        #expect(!BillingCustomerMatch.matches(customerName: "Marie Borders", haystack: haystack))
        #expect(!BillingCustomerMatch.matches(customerName: "Anchor Church", haystack: haystack))
    }

    @Test func noMatchReturnsNil() {
        #expect(BillingCustomerMatch.best(in: ["Anchor Church", "Marie Borders"],
                                          haystack: "Zebra Summary zebra.html") == nil)
    }

    // MARK: - HTML helpers

    @Test func decodesNamedAndNumericEntities() {
        #expect(BillingHTML.clean("Tom &amp; Jerry") == "Tom & Jerry")
        #expect(BillingHTML.clean("a&nbsp;b") == "a b")
        #expect(BillingHTML.clean("&#72;&#105;") == "Hi")
        #expect(BillingHTML.clean("&#x48;&#x69;") == "Hi")
    }

    @Test func collapsesWhitespaceAcrossNewlines() {
        #expect(BillingHTML.clean("  one\n   two \n\n three  ") == "one two three")
    }

    @Test func punctuationIsNotLeftFloatingAfterInlineTags() {
        #expect(BillingHTML.clean("<b>Events system rebuilt</b>, three phases")
                == "Events system rebuilt, three phases")
        #expect(BillingHTML.clean("the dashboard <b>home redesign</b>, and backups.")
                == "the dashboard home redesign, and backups.")
        #expect(BillingHTML.clean("upload (<b>7 files</b>)") == "upload (7 files)")
        #expect(BillingHTML.clean("ends here <b>now</b>.") == "ends here now.")
    }

    @Test func leadingDotFilenamesKeepTheirSpace() {
        // "a true .xlsx" is correct prose; only sentence-ending periods tighten.
        #expect(BillingHTML.clean("export as a true .xlsx mirroring the sheet")
                == "export as a true .xlsx mirroring the sheet")
        #expect(BillingHTML.clean("visit .com sites .") == "visit .com sites.")
    }

    @Test func deliverableTextHasNoFloatingCommas() throws {
        let summary = try BillingSummaryParser.parse(julyHTML)
        for deliverable in summary.deliverables {
            #expect(!deliverable.text.contains(" ,"))
            #expect(!deliverable.text.contains(" ;"))
        }
    }
}
