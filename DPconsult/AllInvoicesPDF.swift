import UIKit
import PDFKit

// Generates a PDF listing all invoices, grouped by status, with a themed header
enum AllInvoicesPDF {
    @discardableResult
    private static func draw(_ text: String, at: CGPoint, font: UIFont, width: CGFloat = .greatestFiniteMagnitude, align: NSTextAlignment = .left, color: UIColor = .black) -> CGFloat {
        let para = NSMutableParagraphStyle(); para.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
        let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
        let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
        (text as NSString).draw(in: CGRect(origin: at, size: CGSize(width: width, height: size.height)), withAttributes: attrs)
        return ceil(size.height)
    }

    private static func drawRight(_ text: String, in rect: CGRect, font: UIFont, color: UIColor = .black) {
        let para = NSMutableParagraphStyle(); para.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    private static func measure(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
        let rect = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
        return ceil(size.height)
    }

    private static func drawLogo(named: String, at: CGPoint, maxWidth: CGFloat) -> CGFloat {
        guard let img = UIImage(named: named) else { return 0 }
        let scale = min(1, maxWidth / img.size.width)
        let w = img.size.width * scale
        let h = img.size.height * scale
        img.draw(in: CGRect(x: at.x, y: at.y, width: w, height: h))
        return h
    }

    private static func money(_ v: Double) -> String { String(format: "$%.2f", v) }

    static func render(invoices: [SDInvoice], customers: [SDCustomer], paymentsByInvoice: [Int: Double] = [:]) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let margin: CGFloat = 36

        // Fonts & theme
        let h1 = UIFont.systemFont(ofSize: 22, weight: .bold)
        let h2 = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let body = UIFont.systemFont(ofSize: 11)
        let small = UIFont.systemFont(ofSize: 9)
        let stripe = UIColor(white: 0.965, alpha: 1)
        let blue = UIColor.systemBlue
        let orange = UIColor.systemOrange

        // Column positions
        let numX = margin + 10
        let statusX = numX + 70   // narrower Status column
        let custX = statusX + 80  // give more room to Customer
        let issueX = page.width - margin - 220

        let rightX = page.width - margin
        let balRect   = CGRect(x: rightX - 70,  y: 0, width: 70, height: 16)
        let paidRect  = CGRect(x: balRect.minX - 70, y: 0, width: 70, height: 16)
        let totalRect = CGRect(x: paidRect.minX - 80, y: 0, width: 80, height: 16)

        func header(_ ctx: UIGraphicsPDFRendererContext) -> CGFloat {
            var y = margin
            // Logo top-right
            let logoH = drawLogo(named: "DPLogo", at: CGPoint(x: page.width - margin - 120, y: y), maxWidth: 90)

            // Title + accent
            let titleH = draw("All Invoices", at: CGPoint(x: margin, y: y), font: h1)
            let g = UIGraphicsGetCurrentContext()!
            g.setFillColor(orange.cgColor)
            g.fill(CGRect(x: margin, y: y + titleH + 4, width: 150, height: 3))
            y += titleH + 18

            // Generated date
            let df = DateFormatter(); df.dateStyle = .medium
            y += draw("Generated: \(df.string(from: Date()))", at: CGPoint(x: margin, y: y), font: small, color: .gray)
            y = max(y, margin + logoH + 8)
            y += 12
            return y
        }

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y = header(ctx)
            let g = UIGraphicsGetCurrentContext()!

            // Group invoices by status
            let grouped = Dictionary(grouping: invoices) { $0.status.lowercased() }
            let order = ["draft", "billable", "invoice", "sent", "partial", "paid"]
            let keys = grouped.keys.sorted { (a, b) in
                let ia = order.firstIndex(of: a) ?? Int.max
                let ib = order.firstIndex(of: b) ?? Int.max
                return ia == ib ? a < b : ia < ib
            }

            // Date formatter for columns
            let colDF = DateFormatter(); colDF.dateFormat = "yyyy-MM-dd"

            func drawTableHeader() {
                let headerH: CGFloat = 24 // slightly taller to avoid clipping
                g.setFillColor(blue.cgColor)
                g.fill(CGRect(x: margin - 10, y: y, width: page.width - margin*2 + 10, height: headerH))
                _ = draw("Invoice #", at: CGPoint(x: numX,    y: y + 6), font: h2, color: .white)
                _ = draw("Status",    at: CGPoint(x: statusX, y: y + 6), font: h2, color: .white)
                _ = draw("Customer",  at: CGPoint(x: custX,   y: y + 6), font: h2, color: .white)
                _ = draw("Issued",    at: CGPoint(x: issueX,  y: y + 6), font: h2, color: .white)
                drawRight("Total",    in: totalRect.offsetBy(dx: 0, dy: y + 4), font: h2, color: .white)
                drawRight("Paid",     in: paidRect.offsetBy(dx: 0, dy: y + 4), font: h2, color: .white)
                drawRight("Balance",  in: balRect.offsetBy(dx: 0, dy: y + 4), font: h2, color: .white)
                y += headerH + 2
            }

            func ensureRoom(_ needed: CGFloat) {
                if y + needed > page.height - margin - 30 {
                    ctx.beginPage(); y = header(ctx)
                }
            }

            for key in keys {
                // Group header
                ensureRoom(28)
                g.setFillColor(orange.withAlphaComponent(0.1).cgColor)
                g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: 22))
                _ = draw("STATUS: \(key.capitalized)", at: CGPoint(x: margin + 10, y: y + 4), font: h2, color: .black)
                y += 22

                // Table header for the group
                drawTableHeader()

                // Rows
                let rows = (grouped[key] ?? []).sorted { $0.issueDate < $1.issueDate }
                var rowIndex = 0
                for inv in rows {
                    let num = "#\(inv.invoiceNumber)"
                    let status = inv.status.capitalized
                    let customer = inv.customer?.name ?? "Customer"
                    let issue = colDF.string(from: inv.issueDate)

                    // Column widths (no Due column)
                    let numW: CGFloat = statusX - numX - 8
                    let statusW: CGFloat = custX - statusX - 8

                    let custDataX = max(margin, custX - 8) // shift data ~8px left
                    let custDataW = (issueX - custDataX) - 8
                    let hCustomer = measure(customer, width: custDataW, font: body)
                    let rowH = max(18, hCustomer + 4)

                    ensureRoom(rowH)

                    if rowIndex % 2 == 1 {
                        g.setFillColor(stripe.cgColor)
                        g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: rowH))
                    }

                    _ = draw(num,    at: CGPoint(x: numX,    y: y + 2), font: body, width: numW)
                    _ = draw(status, at: CGPoint(x: statusX, y: y + 2), font: body, width: statusW)
                    _ = draw(customer, at: CGPoint(x: custDataX, y: y + 2), font: body, width: custDataW)
                    let issueW: CGFloat = (totalRect.origin.x - issueX) - 12
                    _ = draw(issue,  at: CGPoint(x: issueX,  y: y + 2), font: body, width: issueW)

                    // Compute totals/paid/balance (invoice fields only)
                    let items = inv.sortedItems
                    let itemsSum = items.reduce(0) { $0 + $1.amount }
                    let baseTotal = max(inv.total, inv.subtotal + inv.tax, itemsSum + inv.tax)
                    let paidDisplay = inv.amountPaid
                    let correctedBalance = max(0, baseTotal - paidDisplay)
                    drawRight(money(baseTotal),        in: totalRect.offsetBy(dx: 0, dy: y + 2), font: body)
                    drawRight(money(paidDisplay),      in: paidRect.offsetBy(dx: 0, dy: y + 2), font: body)
                    drawRight(money(correctedBalance), in: balRect.offsetBy(dx: 0, dy: y + 2), font: body)

                    y += rowH
                    rowIndex += 1
                }

                // Spacer between groups
                y += 6
            }

            // Footer line
            g.setStrokeColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            g.setLineWidth(0.5)
            g.move(to: CGPoint(x: margin, y: page.height - margin - 20))
            g.addLine(to: CGPoint(x: page.width - margin, y: page.height - margin - 20))
            g.strokePath()

            let foot = "DP Consulting — All Invoices Report"
            _ = draw(foot, at: CGPoint(x: margin, y: page.height - margin - 14), font: small, width: page.width - margin*2, align: .center, color: .gray)
        }
    }
}
