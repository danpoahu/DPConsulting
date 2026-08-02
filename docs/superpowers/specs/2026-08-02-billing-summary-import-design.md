# Billing Summary → Invoice Import

**Date:** 2026-08-02
**App:** DPconsult (Mac Catalyst + iPad, SwiftData)
**Status:** Approved, ready for implementation plan

## Purpose

Each month a client work-summary HTML is generated into `/Volumes/Xcode_Projects/Reports/`
containing an "Hours by week" table. Turning that into an invoice is currently manual
retyping: one line item per week, then a discount line computed by hand.

This feature reads the summary file and produces the pre-filled invoice, leaving the
existing invoice editor as the only thing that writes to SwiftData.

Immediate use: LDAH July 2026 — five weekly lines, 93.75 h gross, billed at $1,150.00.

## Scope

In scope:

- Parse the "Hours by week" table out of a billing-summary HTML file.
- Parse the "Major deliverables" table and attach each deliverable to the week it falls in,
  so every line item carries client-readable detail in its Notes.
- Parse the "For the invoice" block into the invoice-level Notes.
- Editable preview of the parsed weeks and their notes before anything is created.
- Automatic "Professional Discount" line computed from a target invoice total.
- Hand the resulting line items to `DPInvoicingView` unsaved.

Out of scope (explicit non-goals):

- Import history or re-importing onto an existing invoice.
- Any change to invoice PDF rendering.
- Any change to tax handling — the existing `SDCompanySettings.salesTax` path applies untouched.
- Any change to the journal-posting helpers.
- Parsing the "Also delivered" bullet list — its dates are embedded in prose in
  inconsistent forms (`7-09`, `7-29/30`, none at all) and cannot be mapped to weeks
  reliably. The user can paste anything from it by hand.

## User Flow

```
Invoicing list → "Import Summary" toolbar button
  → .fileImporter (allowedContentTypes: [.html])
  → security-scoped read of the chosen file
  → BillingSummaryParser.parse(html)
  → preview sheet: editable rows + customer + rate + "Bill this amount"
  → Create
  → sheet dismisses; DPInvoicingView opens pre-filled and UNSAVED
  → user presses Save & PDF as normal
```

Nothing is written to SwiftData or CloudKit until the user saves in the editor.

## Components

### New file: `DPconsult/DPBillingImport.swift`

Pure data + parser, then the view. No SwiftData in the parser.

```swift
struct BillingWeek: Identifiable, Hashable {
    let id: UUID
    var label: String       // "Jul 1 – 5"
    var focus: String       // "Membership build-up, PayPal integration, announcement tokens"
    var commits: Int        // 21
    var hours: Double       // 5.1
    var startDay: Int       // 1   — parsed from label
    var endDay: Int         // 5   — parsed from label
    var notes: String       // deliverables falling in this week, joined; editable
}

struct BillingDeliverable {
    var month: Int          // 7
    var startDay: Int       // 25
    var endDay: Int         // 27  — equals startDay for single-date rows
    var text: String        // "Second parent on contacts (both parents receive …"
}

struct BillingSummary {
    var title: String              // from <h1>, e.g. "LDAH — July 2026 Work Summary"
    var weeks: [BillingWeek]
    var statedTotalHours: Double?  // from the class="tot" row, nil if absent
    var deliverables: [BillingDeliverable]  // empty if the table is absent
    var invoiceBlurb: String?      // from the "For the invoice" block, nil if absent
}

enum BillingSummaryParseError: Error {
    case unreadableFile
    case noTable      // no "Hours by week" heading followed by a table
    case noRows       // table found but no usable data rows
}

enum BillingSummaryParser {
    static func parse(_ html: String) throws(BillingSummaryParseError) -> BillingSummary
}
```

`struct DPBillingImportView: View` — the preview sheet.

### Modified: `DPconsult/InvoiceView.swift`

Three edits, all additive:

1. `DPInvoicingView.init` gains `seedItems: [DPInvoiceItemDraft] = []` and
   `seedNotes: String = ""`, stored as `let`. All five existing call sites
   (`CustomerView.swift:204`, `ReportsView.swift:535`, `InvoiceView.swift:976`,
   `:977`, `:1321`) use the defaults and are unaffected.
2. `prefillIfNeeded()`, inside the `existing == nil` branch and before `didPrefill = true`:
   apply `items = seedItems` and `invoiceNotes = seedNotes` when non-empty.
3. `DPInvoicesListView`: add `case importing` to `EditorRoute`, an "Import Summary"
   toolbar button beside `+`, and the sheet wiring that on completion routes to
   `DPInvoicingView(customer:seedItems:seedNotes:)`.

### New file: `DPconsultTests/BillingSummaryParserTests.swift`

Swift Testing (`import Testing`, `@Test`, `#expect`), fresh instance per test.

## Parser Algorithm

1. Locate the heading `Hours by week` (case-insensitive). If absent, throw `.noTable`.
2. From that offset, take the substring between the next `<table` and the following
   `</table>`. If either is absent, throw `.noTable`.
3. Split into `<tr ...>...</tr>` rows.
4. Classify each row:
   - contains `<th` → header, skip
   - `<tr` carries `class="tot"` → total row, parse hours into `statedTotalHours`, skip
   - otherwise → data row
5. For a data row, extract the `<td ...>...</td>` cell inner texts in order.
   Require at least 4 cells; rows with fewer are skipped.
   - cell 0 → `label`
   - cell 1 → `focus`
   - cell 2 → `commits` (digits only, default 0)
   - cell 3 → `hours`
6. Cell text cleanup, in order: strip tags (`<[^>]+>` → ""), decode entities, collapse
   runs of whitespace to a single space, trim.
7. Numeric cleanup: keep `0-9` and `.`, drop everything else, then `Double(...)`.
   This turns `90.0&nbsp;h` into `90.0`. A cell yielding no number is `0`.
8. `title` comes from the first `<h1>...</h1>`, cleaned the same way; empty string if absent.
9. If no data rows survived, throw `.noRows`.

At this stage each `BillingWeek` has an empty `notes`; day ranges and notes are filled by
the two passes described next. Parsing order is: hours table (required) → week day ranges
→ deliverables table (optional) → note assembly → "For the invoice" block (optional).

Entity decoding covers `&nbsp;` (→ space), `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#39;`,
and numeric `&#NNN;` / `&#xHH;`. En dashes and arrows appear as literal UTF-8 in the
source files and need no decoding.

Rows are returned in document order.

### Week Day Ranges

The week label carries the day range: `"Jul 1 – 5"` → `startDay 1`, `endDay 5`.
Take the first two integers found in the label; if only one is found, `endDay = startDay`;
if none, both are `0` and the week simply collects no deliverables. The month name is
read from the label's leading alphabetic token (`Jul` → 7) and is used to filter
deliverables; unrecognised month names yield `0`, which matches nothing.

### Deliverables Table

Optional. Absent in some summaries (the June 2026 file uses numbered prose sections
instead), and its absence is never an error — it just means empty line notes.

1. Locate the heading `Major deliverables`. If absent, `deliverables` is empty.
2. Take the following `<table>` and split into `<tr>` rows; skip header rows.
3. Cell 0 is the date, cell 1 the description. Rows with fewer than 2 cells are skipped.
4. Date cell forms seen in real files: `7-24`, `7-25 → 7-27`, `~6-25`. Parse by taking
   all integers in the cell after stripping a leading `~`:
   - two integers `M, D` → month `M`, `startDay = endDay = D`
   - four integers `M, D1, M2, D2` → month `M`, `startDay = D1`, `endDay = D2`
     (a range crossing months is clamped: if `M2 != M`, `endDay = 31`)
   - anything else → row skipped
5. Description cell is cleaned with the same tag-strip/entity-decode/collapse routine.
   `<b>` emphasis is discarded, leaving plain text.

### "For the invoice" Block

Optional. Locate the heading `For the invoice`, take the following `<table>`, and clean
the first `<td>`'s inner text. The `<br>` between the bold title and the grey detail line
is converted to `" — "` before tag-stripping so the two parts stay legible on one run:

> `July 2026 — LDAH development — Staff dashboard, public website, mobile app and Cloud Functions. 28 working days, 391 commits, 14 session reports.`

This becomes the seeded invoice-level Notes. If the block is absent, the seed falls back
to the parsed `title`.

### Assembling Line Notes

For each week, collect every deliverable where `deliverable.month == week.month` and the
day ranges overlap (`deliverable.startDay <= week.endDay && deliverable.endDay >= week.startDay`),
in document order, joined with `" · "`.

A deliverable spanning a week boundary appears in **both** weeks. That is intentional —
the client is reading a description of what that week's hours went to, not a partition —
and every note is editable before Create.

## Discount Arithmetic

```
gross    = (Σ row.hours) × rate          // rounded to 2 dp
discount = gross − target                // rounded to 2 dp
```

- `target` blank, zero, or equal to `gross` → no discount line.
- `0 < target < gross` → append a discount line.
- `target > gross` → Create is disabled with an inline reason. No surcharge lines.
- `target < 0` → treated as invalid; Create disabled.

Discount line shape, matching the existing invoice 2066 precedent so the PDF renders it
the way prior invoices did:

| field | value |
|---|---|
| `description` | `"Professional Discount"` |
| `qty` | `1` |
| `rate` | `-discount` |
| `serviceId` | `""` |

Week line shape:

| field | value |
|---|---|
| `description` | `"\(label): \(focus)"` |
| `qty` | `hours` |
| `rate` | the sheet's rate value |
| `notes` | the week's assembled deliverables (see above) |
| `serviceId` | `""` |

The discount line's `notes` is empty.

Both notes fields reach the client: `DPInvoicePDF` draws line notes in italic beneath
each description (`DPInvoicePDF.swift:441`) and the invoice-level notes in the
highlighted block at bottom-left (`:504`).

## Import Sheet

Sections, top to bottom:

1. **File** — "Choose Summary File…" button, then the chosen filename and parsed title.
2. **Customer** — picker over `SDCustomer`, pre-selected by the match rule below;
   falls back to no selection. Always overridable.
3. **Rate** — decimal field, defaults to `50.00`.
4. **Weeks** — editable list. Each row: label (text), focus (text), hours (decimal),
   and a multi-line **Notes** field pre-filled with that week's deliverables. Swipe to
   delete. "Add row" appends an empty row. No drag reorder.
5. **Invoice notes** — multi-line field pre-filled from the "For the invoice" block.
6. **Totals** — gross hours, gross dollars, "Bill this amount" decimal field, computed
   discount, resulting total.
7. **Create** — builds the drafts, dismisses, opens the editor.

Every notes field is editable here and again in the invoice editor afterwards. Because
these strings are what the client reads, nothing is auto-truncated — long notes make the
PDF row taller, which `DPInvoicePDF` already measures and handles.

### Customer Match Rule

A plain substring match does not work for the real case: the summary title is
`LDAH — July 2026 Work Summary` while the customer record is
`Leadership in Disabilities & Achievement of Hawai'i`. Neither string contains the other.

The rule, applied case-insensitively against a haystack of the parsed `title` plus the
chosen file's name:

1. **Name match** — the customer's name appears in the haystack, or any word of the
   customer's name with 4+ letters appears in the haystack.
2. **Acronym match** — build an acronym from the customer's name by taking the first
   letter of each word of 3+ letters (skipping `in`, `of`, `&`, `the`, and the like by
   virtue of the length rule). `Leadership in Disabilities & Achievement of Hawai'i`
   → `LDAH`. Match if that acronym, 2+ characters, appears in the haystack as a
   standalone token.

First customer satisfying either rule wins, checked in `SDCustomer.name` order. If none
match, nothing is pre-selected and the user picks. The rule is a convenience only — a
wrong guess costs one tap, and Create is disabled until a customer is chosen.

## Error Handling

| condition | behaviour |
|---|---|
| `.noTable` | Alert: "Couldn't find an 'Hours by week' table in that file." Sheet stays open. |
| `.noRows` | Alert: "Found the table but no week rows." Sheet stays open. |
| "Major deliverables" table absent | **Not an error.** Week notes are empty; user types them. |
| "For the invoice" block absent | **Not an error.** Invoice notes seed falls back to the `<h1>` title. |
| `.unreadableFile` / file read throws | Alert with the underlying `localizedDescription`. |
| security-scoped access denied | Same as unreadable-file. |
| Σ parsed hours ≠ `statedTotalHours` | Amber inline warning showing both figures. **Non-blocking** — the user edits rows deliberately. |
| no customer selected | Create disabled. |
| rate ≤ 0 | Create disabled. |
| no rows | Create disabled. |
| `target > gross` or `target < 0` | Create disabled with inline reason. |

Mac Catalyst is sandboxed, so the file read must bracket with
`startAccessingSecurityScopedResource()` and a `defer` calling
`stopAccessingSecurityScopedResource()`.

## Testing

Parser tests are pure — no SwiftData, no UI, no container.

1. Real July fixture → 5 weeks; `statedTotalHours == 90.0`; first label `"Jul 1 – 5"`;
   Σ hours == 90.0.
2. Focus text with an arrow and an en dash survives intact
   (`"Memberships live; Connect-Gen worksheet phases 1–3; flyer→event AI"`).
3. Total row is excluded from `weeks` (count is 5, not 6).
4. `90.0&nbsp;h` parses to `90.0`.
5. HTML with no "Hours by week" heading → throws `.noTable`.
6. Table present, only a header row → throws `.noRows`.
7. `<h1>` is captured into `title`.
8. Discount arithmetic: gross 93.75 h × $50 = $4,687.50, target $1,150.00
   → discount $3,537.50, total $1,150.00.
9. Discount arithmetic: target == gross → no discount line.
10. Acronym build: `"Leadership in Disabilities & Achievement of Hawai'i"` → `"LDAH"`.
11. Customer match: haystack `"LDAH — July 2026 Work Summary LDAH-July-2026-billing-summary.html"`
    matches the LDAH customer and not `"Marie Borders"`.
12. Week label `"Jul 1 – 5"` → month 7, days 1…5. `"Jul 27 – 31"` → days 27…31.
13. Deliverable date `"7-24"` → month 7, days 24…24. `"7-25 → 7-27"` → days 25…27.
    `"~6-25"` → month 6, days 25…25.
14. Deliverable-to-week assignment on the July fixture: `Jul 1 – 5` collects none;
    `Jul 6 – 12` collects the 7-06→7-07 and 7-09→7-14 rows; `Jul 27 – 31` collects
    the 7-25→7-27, 7-29 and 7-30→7-31 rows.
15. A deliverable spanning a week boundary (7-19 → 7-20) appears in both `Jul 13 – 19`
    and `Jul 20 – 26`.
16. A summary with no "Major deliverables" heading parses successfully with empty
    deliverables and empty week notes — not an error.
17. "For the invoice" block flattens its `<br>` to `" — "`, yielding
    `"July 2026 — LDAH development — Staff dashboard, …14 session reports."`
18. Missing "For the invoice" block → invoice notes seed falls back to the `<h1>` title.

The acronym builder and the match rule must therefore be free functions taking plain
strings, not methods needing an `SDCustomer` instance, so they stay testable without a
SwiftData container.

Fixtures are inline string literals in the test file, trimmed from the real
July and June summaries. No file-system access in tests.

## Acceptance Criteria

Running the app and importing `LDAH-July-2026-billing-summary.html` produces, after
editing the final week from 19.0 to 22.75 and entering 1150.00:

- Customer: Leadership in Disabilities & Achievement of Hawai'i
- Invoice number: 2072 (from `nextInvoiceNumber`, on save)
- Six line items:

| # | description | qty | rate | amount |
|---|---|---|---|---|
| 1 | Jul 1 – 5: Membership build-up, PayPal integration, announcement tokens | 5.10 | 50.00 | 255.00 |
| 2 | Jul 6 – 12: Memberships live; Connect-Gen worksheet phases 1–3; flyer→event AI | 18.80 | 50.00 | 940.00 |
| 3 | Jul 13 – 19: Dashboard release run; member portal built; screening consent | 22.90 | 50.00 | 1145.00 |
| 4 | Jul 20 – 26: Google Play; recordings archive; Events rebuilt; second parent | 24.20 | 50.00 | 1210.00 |
| 5 | Jul 27 – 31: Home redesign; PTI export; portal live; first members; data quality | 22.75 | 50.00 | 1137.50 |
| 6 | Professional Discount | 1.00 | -3537.50 | -3537.50 |

- Subtotal / total: **$1,150.00**
- Nothing written to SwiftData until Save is pressed in the editor.

Line notes, drawn in italic under each description on the PDF:

| line | notes seeded from |
|---|---|
| Jul 1 – 5 | *(none — no deliverable rows fall in this week)* |
| Jul 6 – 12 | Paid memberships went live · Connect-Gen Parent Report Worksheet, three phases |
| Jul 13 – 19 | Connect-Gen worksheet · Dashboard release run · Member portal built · Multi-recipient contact emails |
| Jul 20 – 26 | Multi-recipient contact emails · Google Play production access + recordings archive · Events system rebuilt · Second parent on contacts |
| Jul 27 – 31 | Second parent on contacts · Member portal went live · First real members through the portal |

(Each is the deliverable's full sentence from the summary, not the shortened label above.)

Invoice-level Notes block:

> July 2026 — LDAH development — Staff dashboard, public website, mobile app and Cloud
> Functions. 28 working days, 391 commits, 14 session reports.

## Implementation Risks

- The working tree has six uncommitted modified files, including the two
  `DPconsultApp.swift` fixes recorded as critical and never committed (the `runDedup()`
  removal and the explicit store URL). Commit `DPconsultApp.swift` on its own before
  starting, so this work stays separable. Never `git add -A` — the repo root holds an
  `AuthKey_*.p8`.
- `InvoiceView.swift` is ~80KB. Keep the three edits surgical; do not refactor it.
- Fallback if the build cannot be made to work in time: the six line items above are
  typed by hand into a new invoice. The feature is a convenience, not the only path
  to the invoice.
