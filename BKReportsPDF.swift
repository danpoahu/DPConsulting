import UIKit
import PDFKit

enum BKReportsPDF {
    // Simple text drawing helpers
    private static func draw(_ text: String, at: CGPoint, font: UIFont, color: UIColor = .black) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: at, withAttributes: attrs)
    }

    private static func drawRight(_ text: String, in rect: CGRect, font: UIFont, color: UIColor = .black) {
        let para = NSMutableParagraphStyle(); para.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
    
    private static func drawLogo(named: String, at: CGPoint, maxWidth: CGFloat) -> CGFloat {
        guard let img = UIImage(named: named) else { return 0 }
        let scale = min(1, maxWidth / img.size.width)
        let w = img.size.width * scale
        let h = img.size.height * scale
        img.draw(in: CGRect(x: at.x, y: at.y, width: w, height: h))
        return h
    }

    static func renderBalanceSheet(bs: (assets: [(SDAccount, Double)], liabilities: [(SDAccount, Double)], equity: [(SDAccount, Double)], totals: (assets: Double, liabilities: Double, equity: Double), retainedEarnings: Double), pl: (income: [(SDAccount, Double)], expenses: [(SDAccount, Double)], net: Double)? = nil, salesRevenue: Double = 0, periodLabel: String = "Year to Date") -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter 8.5"x11" at 72dpi
        let margin: CGFloat = 36

        // Fonts & theme
        let h1 = UIFont.systemFont(ofSize: 24, weight: .bold)
        let h2 = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let body = UIFont.systemFont(ofSize: 12)
        let small = UIFont.systemFont(ofSize: 10)

        let blue = UIColor.systemBlue
        let orange = UIColor.systemOrange
        let stripe = UIColor(white: 0.965, alpha: 1)
        let hairline = UIColor.black.withAlphaComponent(0.18).cgColor

        // Column geometry
        let gutter: CGFloat = 24
        let colWidth = (page.width - margin * 2 - gutter) / 2
        let leftX = margin
        let rightX = margin + colWidth + gutter

        func money(_ v: Double) -> String { String(format: "$%.2f", v) }

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let g = UIGraphicsGetCurrentContext()!
            var y = margin

            // Header: logo on the right, title on the left
            let logoH = drawLogo(named: "DPLogo", at: CGPoint(x: page.width - margin - 140, y: y), maxWidth: 110)

            // Title + accent
            let titleH = ("Balance Sheet" as NSString).size(withAttributes: [.font: h1]).height
            draw("Balance Sheet", at: CGPoint(x: margin, y: y), font: h1)
            g.setFillColor(orange.cgColor)
            g.fill(CGRect(x: margin, y: y + titleH + 4, width: 160, height: 3))
            y += titleH + 18

            // Dates
            let asOf = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
            draw("As of \(asOf)", at: CGPoint(x: margin, y: y), font: small, color: .darkGray)
            y += 14
            draw("Generated: \(asOf)", at: CGPoint(x: margin, y: y), font: small, color: .gray)
            y += 8

            // Ensure we start content below the logo to avoid overlap
            y = max(y, margin + logoH + 28)

            // Divider under header
            g.setStrokeColor(hairline)
            g.setLineWidth(0.5)
            g.move(to: CGPoint(x: margin, y: y))
            g.addLine(to: CGPoint(x: page.width - margin, y: y))
            g.strokePath()
            y += 10

            // Column-specific helpers
            func columnHeader(_ title: String, x: CGFloat, y: CGFloat) -> CGFloat {
                let headerH: CGFloat = 22
                g.setFillColor(blue.cgColor)
                g.fill(CGRect(x: x, y: y, width: colWidth, height: headerH))
                draw(title, at: CGPoint(x: x + 10, y: y + 4), font: h2, color: .white)
                return y + headerH + 4
            }

            func columnRow(name: String, amount: Double, x: CGFloat, y: CGFloat, index: Int) -> CGFloat {
                let rowH: CGFloat = 18
                if index % 2 == 1 {
                    g.setFillColor(stripe.cgColor)
                    g.fill(CGRect(x: x, y: y, width: colWidth, height: rowH))
                }
                draw(name, at: CGPoint(x: x + 10, y: y + 2), font: body)
                drawRight(money(amount), in: CGRect(x: x + 10, y: y, width: colWidth - 20, height: rowH), font: body)
                return y + rowH
            }

            func columnTotal(label: String, amount: Double, x: CGFloat, y: CGFloat) -> CGFloat {
                g.setFillColor(orange.withAlphaComponent(0.1).cgColor)
                g.fill(CGRect(x: x, y: y, width: colWidth, height: 20))
                draw(label, at: CGPoint(x: x + 10, y: y + 3), font: h2)
                drawRight(money(amount), in: CGRect(x: x + 10, y: y, width: colWidth - 20, height: 20), font: h2)
                return y + 24
            }

            // Left column: Assets
            var yLeft = y
            yLeft = columnHeader("Assets", x: leftX, y: yLeft)
            for (idx, item) in bs.assets.enumerated() {
                yLeft = columnRow(name: item.0.name, amount: item.1, x: leftX, y: yLeft, index: idx)
            }
            yLeft = columnTotal(label: "Total Assets", amount: bs.totals.assets, x: leftX, y: yLeft + 6)

            // Right column: Liabilities and Equity
            var yRight = y
            yRight = columnHeader("Liabilities", x: rightX, y: yRight)
            for (idx, item) in bs.liabilities.enumerated() {
                yRight = columnRow(name: item.0.name, amount: item.1, x: rightX, y: yRight, index: idx)
            }
            yRight = columnTotal(label: "Total Liabilities", amount: bs.totals.liabilities, x: rightX, y: yRight + 6)

            yRight = yRight + 8
            yRight = columnHeader("Equity", x: rightX, y: yRight)
            var eqIndex = 0
            for item in bs.equity {
                yRight = columnRow(name: item.0.name, amount: item.1, x: rightX, y: yRight, index: eqIndex)
                eqIndex = eqIndex + 1
            }
            // Retained earnings as a distinct row within Equity
            yRight = columnRow(name: "Retained Earnings", amount: bs.retainedEarnings, x: rightX, y: yRight, index: eqIndex)
            eqIndex = eqIndex + 1
            yRight = columnTotal(label: "Total Equity", amount: bs.totals.equity, x: rightX, y: yRight + 6)

            // Combined total on the right
            let rightTotal = bs.totals.liabilities + bs.totals.equity
            yRight = columnTotal(label: "Total L&E", amount: rightTotal, x: rightX, y: yRight + 2)

            // Footer check
            let bottomY = max(yLeft, yRight) + 10
            g.setStrokeColor(hairline)
            g.setLineWidth(0.5)
            g.move(to: CGPoint(x: margin, y: bottomY))
            g.addLine(to: CGPoint(x: page.width - margin, y: bottomY))
            g.strokePath()

            let diff = bs.totals.assets - rightTotal
            let checkText = String(format: "Check (Assets - (L+E)): $%.2f", diff)
            let color: UIColor = abs(diff) < 0.005 ? .systemGreen : .systemRed
            draw(checkText, at: CGPoint(x: margin, y: bottomY + 6), font: body, color: color)

            // ── Page 2: Profit & Loss ──
            if let pl = pl {
                ctx.beginPage()
                let g2 = UIGraphicsGetCurrentContext()!
                var y2 = margin

                // Header: logo on the right, title on the left
                let logoH2 = drawLogo(named: "DPLogo", at: CGPoint(x: page.width - margin - 140, y: y2), maxWidth: 110)

                let titleH2 = ("Profit & Loss" as NSString).size(withAttributes: [.font: h1]).height
                draw("Profit & Loss", at: CGPoint(x: margin, y: y2), font: h1)
                g2.setFillColor(orange.cgColor)
                g2.fill(CGRect(x: margin, y: y2 + titleH2 + 4, width: 160, height: 3))
                y2 += titleH2 + 18

                let asOf2 = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
                draw(periodLabel, at: CGPoint(x: margin, y: y2), font: small, color: .darkGray)
                y2 += 14
                draw("Generated: \(asOf2)", at: CGPoint(x: margin, y: y2), font: small, color: .gray)
                y2 += 8
                y2 = max(y2, margin + logoH2 + 28)

                // Divider
                g2.setStrokeColor(hairline)
                g2.setLineWidth(0.5)
                g2.move(to: CGPoint(x: margin, y: y2))
                g2.addLine(to: CGPoint(x: page.width - margin, y: y2))
                g2.strokePath()
                y2 += 10

                let fullWidth = page.width - margin * 2

                // Income section header
                func sectionHeader(_ title: String, y: CGFloat) -> CGFloat {
                    let headerH: CGFloat = 22
                    g2.setFillColor(blue.cgColor)
                    g2.fill(CGRect(x: margin, y: y, width: fullWidth, height: headerH))
                    draw(title, at: CGPoint(x: margin + 10, y: y + 4), font: h2, color: .white)
                    return y + headerH + 4
                }

                func sectionRow(name: String, amount: Double, y: CGFloat, index: Int) -> CGFloat {
                    let rowH: CGFloat = 18
                    if index % 2 == 1 {
                        g2.setFillColor(stripe.cgColor)
                        g2.fill(CGRect(x: margin, y: y, width: fullWidth, height: rowH))
                    }
                    draw(name, at: CGPoint(x: margin + 10, y: y + 2), font: body)
                    drawRight(money(amount), in: CGRect(x: margin + 10, y: y, width: fullWidth - 20, height: rowH), font: body)
                    return y + rowH
                }

                func sectionTotal(label: String, amount: Double, y: CGFloat, positive: Bool = true) -> CGFloat {
                    g2.setFillColor(orange.withAlphaComponent(0.1).cgColor)
                    g2.fill(CGRect(x: margin, y: y, width: fullWidth, height: 20))
                    draw(label, at: CGPoint(x: margin + 10, y: y + 3), font: h2)
                    drawRight(money(amount), in: CGRect(x: margin + 10, y: y, width: fullWidth - 20, height: 20), font: h2, color: positive ? .black : .systemRed)
                    return y + 28
                }

                // Income
                y2 = sectionHeader("Income", y: y2)
                y2 = sectionRow(name: "Payments Received (cash basis)", amount: salesRevenue, y: y2, index: 0)
                let totalIncome = salesRevenue
                y2 = sectionTotal(label: "Total Income", amount: totalIncome, y: y2 + 6)

                // Expenses
                y2 = sectionHeader("Expenses", y: y2)
                for (idx, item) in pl.expenses.enumerated() {
                    y2 = sectionRow(name: item.0.name, amount: item.1, y: y2, index: idx)
                }
                let totalExpenses = pl.expenses.reduce(0) { $0 + $1.1 }
                y2 = sectionTotal(label: "Total Expenses", amount: totalExpenses, y: y2 + 6)

                // Net Profit/Loss
                let netPL = totalIncome - totalExpenses
                g2.setStrokeColor(hairline)
                g2.setLineWidth(0.5)
                g2.move(to: CGPoint(x: margin, y: y2))
                g2.addLine(to: CGPoint(x: page.width - margin, y: y2))
                g2.strokePath()
                y2 += 8

                let netColor: UIColor = netPL >= 0 ? .systemGreen : .systemRed
                draw("Net Profit/Loss", at: CGPoint(x: margin + 10, y: y2), font: h1)
                drawRight(money(netPL), in: CGRect(x: margin + 10, y: y2, width: fullWidth - 20, height: 30), font: h1, color: netColor)
            }
        }
    }

    static func renderJournal(entries: [SDJournalEntry], accounts: [SDAccount]) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 36
        let h1 = UIFont.systemFont(ofSize: 20, weight: .bold)
        let h2 = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let body = UIFont.systemFont(ofSize: 11)
        let small = UIFont.systemFont(ofSize: 9)

        func nameFor(_ id: UUID) -> String {
            accounts.first(where: { $0.id == id })?.name ?? "Account"
        }

        let df = DateFormatter(); df.dateStyle = .medium
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let g = UIGraphicsGetCurrentContext()!
            var y = margin

            // Logo top-right
            _ = drawLogo(named: "DPLogo", at: CGPoint(x: page.width - margin - 140, y: y), maxWidth: 120)

            // Title + accent
            let titleH = { () -> CGFloat in
                let h = ("Journal Entries" as NSString).size(withAttributes: [.font: h1]).height
                draw("Journal Entries", at: CGPoint(x: margin, y: y), font: h1)
                return h
            }()
            g.setFillColor(UIColor.systemOrange.cgColor)
            g.fill(CGRect(x: margin, y: y + titleH + 4, width: 140, height: 3))
            y += titleH + 18

            // Subtitle + dates
            draw("Standard debit/credit format", at: CGPoint(x: margin, y: y), font: small, color: .darkGray)
            y += 14
            let gen = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
            draw("Generated: \(gen)", at: CGPoint(x: margin, y: y), font: small, color: .gray)
            y += 16

            // Column headers
            let dateX = margin
            let acctX = margin + 90
            let debitX = page.width - margin - 170
            let creditX = page.width - margin - 60
            draw("Date", at: CGPoint(x: dateX, y: y), font: h2)
            draw("Account", at: CGPoint(x: acctX, y: y), font: h2)
            drawRight("Debit", in: CGRect(x: debitX - 80, y: y, width: 80, height: 14), font: h2)
            drawRight("Credit", in: CGRect(x: creditX - 80, y: y, width: 80, height: 14), font: h2)
            y += 16

            g.setStrokeColor(UIColor.black.withAlphaComponent(0.2).cgColor)
            g.setLineWidth(0.5)
            g.move(to: CGPoint(x: margin, y: y))
            g.addLine(to: CGPoint(x: page.width - margin, y: y))
            g.strokePath()
            y += 6

            for entry in entries.sorted(by: { $0.date < $1.date }) {
                // Entry header
                draw(df.string(from: entry.date), at: CGPoint(x: dateX, y: y), font: body)
                if !entry.memo.isEmpty {
                    draw(entry.memo, at: CGPoint(x: acctX, y: y), font: body, color: .darkGray)
                }
                y += 16

                var totalDeb: Double = 0
                var totalCred: Double = 0
                for line in entry.sortedLines {
                    let name = nameFor(line.accountId)
                    draw(name, at: CGPoint(x: acctX + 8, y: y), font: body)
                    if line.debit > 0 {
                        drawRight(String(format: "$%.2f", line.debit), in: CGRect(x: debitX - 80, y: y, width: 80, height: 14), font: body)
                        totalDeb += line.debit
                    }
                    if line.credit > 0 {
                        drawRight(String(format: "$%.2f", line.credit), in: CGRect(x: creditX - 80, y: y, width: 80, height: 14), font: body)
                        totalCred += line.credit
                    }
                    y += 14
                }

                // Totals per entry
                y += 2
                drawRight(String(format: "$%.2f", totalDeb), in: CGRect(x: debitX - 80, y: y, width: 80, height: 14), font: h2)
                drawRight(String(format: "$%.2f", totalCred), in: CGRect(x: creditX - 80, y: y, width: 80, height: 14), font: h2)
                y += 8

                // Balanced indicator
                let balanced = abs(totalDeb - totalCred) < 0.005
                draw(balanced ? "Balanced" : "Unbalanced", at: CGPoint(x: acctX + 8, y: y), font: small, color: balanced ? .systemGreen : .systemRed)
                y += 14

                // Divider
                g.setStrokeColor(UIColor.black.withAlphaComponent(0.1).cgColor)
                g.move(to: CGPoint(x: margin, y: y))
                g.addLine(to: CGPoint(x: page.width - margin, y: y))
                g.strokePath()
                y += 10

                // Page break if near bottom
                if y > page.height - margin - 80 {
                    ctx.beginPage(); y = margin
                }
            }
        }
    }
}

