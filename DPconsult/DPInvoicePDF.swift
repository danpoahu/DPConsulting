//
//  DPInvoicePDF.swift
//  DPconsult
//
//  Created by Daniel Pellegrini on 9/7/25.
//

import UIKit
import PDFKit

enum DPInvoicePDF {
    // Phone number formatting helper
    private static func formatPhoneNumber(_ phone: String) -> String {
        let digits = phone.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        if digits.count == 10 {
            let area = String(digits.prefix(3))
            let middle = String(digits.dropFirst(3).prefix(3))
            let last = String(digits.suffix(4))
            return "(\(area)) \(middle)-\(last)"
        }
        if digits.count == 11 && digits.hasPrefix("1") {
            let area = String(digits.dropFirst().prefix(3))
            let middle = String(digits.dropFirst(4).prefix(3))
            let last = String(digits.suffix(4))
            return "1 (\(area)) \(middle)-\(last)"
        }
        return phone
    }

    static func render(
        isQuote: Bool,
        number: Int,
        customerName: String,
        issueDate: Date?,
        dueDate: Date?,
        businessName: String,
        businessAddress: String?,
        businessPhone: String?,
        customerAddress: String?,
        customerPhone: String?,
        invoiceNotes: String?,
        lineItems: [[String: Any]],
        subtotal: Double,
        tax: Double,
        total: Double,
        footerText: String? = nil,
        logoName: String = "DPLogo"
    ) -> Data {

        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 36
        let footerHeight: CGFloat = 40
        let pageBottom = page.height - margin - footerHeight

        // Theme
        let brandBlue   = UIColor.systemBlue
        let brandOrange = UIColor.systemOrange
        let stripe      = UIColor(white: 0.965, alpha: 1)
        let hairline    = UIColor.black.withAlphaComponent(0.18).cgColor

        // Columns
        let colW: CGFloat = 240
        let leftX  = margin
        let rightX = page.width - margin - colW

        // Fonts
        let h1    = UIFont.systemFont(ofSize: 28, weight: .bold)
        let h2    = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let h3    = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let body  = UIFont.systemFont(ofSize: 12)
        let small = UIFont.systemFont(ofSize: 10)
        let italic = UIFont.italicSystemFont(ofSize: 11)

        // Table column positions
        let qtyX  = margin
        let descX = margin + CGFloat(60)
        let rateX = page.width - margin - CGFloat(160)
        let amtX  = page.width - margin - CGFloat(70)
        let descWidth = page.width - margin*2 - CGFloat(60) - CGFloat(240)
        let headerH: CGFloat = 22

        // Drawing helpers
        @discardableResult
        func draw(_ text: String, at: CGPoint, font: UIFont, width: CGFloat = .greatestFiniteMagnitude, align: NSTextAlignment = .left, color: UIColor = .black) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.alignment = align
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
            let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
            (text as NSString).draw(in: CGRect(origin: at, size: CGSize(width: width, height: size.height)), withAttributes: attrs)
            return ceil(size.height)
        }

        @discardableResult
        func drawMultiline(_ text: String, at: CGPoint, width: CGFloat, font: UIFont, lineSpacing: CGFloat = 1.35, color: UIColor = .black) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.lineSpacing = lineSpacing; para.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: color]
            let rect = CGRect(x: at.x, y: at.y, width: width, height: .greatestFiniteMagnitude)
            let size = (text as NSString).boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).size
            (text as NSString).draw(in: CGRect(x: at.x, y: at.y, width: width, height: size.height), withAttributes: attrs)
            return ceil(size.height)
        }

        @discardableResult
        func drawKeyValSplit(_ key: String, _ val: String, at: CGPoint, keyFont: UIFont, valFont: UIFont, spacing: CGFloat, labelWidth: CGFloat, valueWidth: CGFloat) -> CGFloat {
            let keyH = draw(key, at: at, font: keyFont, width: labelWidth, align: .right)
            let valH = draw(val, at: CGPoint(x: at.x + labelWidth + CGFloat(8), y: at.y), font: valFont, width: valueWidth, align: .right)
            return max(keyH, valH) + spacing
        }

        func drawLogo(named: String, at: CGPoint, maxWidth: CGFloat) -> CGFloat {
            guard let img = UIImage(named: named) else { return 0 }
            let scale = min(1, maxWidth / img.size.width)
            let w = img.size.width * scale
            let h = img.size.height * scale
            img.draw(in: CGRect(x: at.x, y: at.y, width: w, height: h))
            return h
        }

        func measureText(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
            let size = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs, context: nil).size
            return ceil(max(size.height, 16))
        }

        func drawFooter(_ g: CGContext) {
            guard let f = footerText, !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let footerTop = page.height - margin - CGFloat(34)
            g.setStrokeColor(hairline); g.setLineWidth(CGFloat(0.5))
            g.move(to: CGPoint(x: margin, y: footerTop))
            g.addLine(to: CGPoint(x: page.width - margin, y: footerTop))
            g.strokePath()

            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: small, .paragraphStyle: para, .foregroundColor: UIColor.darkGray]
            (f as NSString).draw(in: CGRect(x: margin, y: footerTop + CGFloat(6), width: page.width - margin*2, height: CGFloat(28)), withAttributes: attrs)
        }

        func drawTableHeader(_ g: CGContext, at y: CGFloat) -> CGFloat {
            g.setFillColor(brandBlue.cgColor)
            g.fill(CGRect(x: margin, y: y, width: page.width - margin*2, height: headerH))
            _ = draw("QTY",         at: CGPoint(x: qtyX,  y: y + CGFloat(4)), font: h2, color: .white)
            _ = draw("Description", at: CGPoint(x: descX, y: y + CGFloat(4)), font: h2, color: .white)
            _ = draw("Rate",        at: CGPoint(x: rateX, y: y + CGFloat(4)), font: h2, width: CGFloat(90), align: .right, color: .white)
            _ = draw("Amount",      at: CGPoint(x: amtX,  y: y + CGFloat(4)), font: h2, width: CGFloat(70), align: .right, color: .white)
            return y + headerH + CGFloat(2)
        }

        func drawContinuationHeader(_ g: CGContext, pageNum: Int) -> CGFloat {
            let title = isQuote ? "QUOTE" : "INVOICE"
            let invNum = number > 0 ? "#\(number)" : ""
            let text = "\(title) \(invNum) — continued (page \(pageNum))"
            var y = margin
            _ = draw(text, at: CGPoint(x: margin, y: y), font: h3, color: brandBlue)
            y += CGFloat(24)
            g.setStrokeColor(hairline); g.setLineWidth(CGFloat(0.5))
            g.move(to: CGPoint(x: margin, y: y))
            g.addLine(to: CGPoint(x: page.width - margin, y: y))
            g.strokePath()
            y += CGFloat(6)
            return y
        }

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let g = UIGraphicsGetCurrentContext()!
            var y = margin
            var pageNum = 1
            var row = 0

            // ===== Page 1 Header =====
            let logoH = drawLogo(named: logoName, at: CGPoint(x: leftX, y: y), maxWidth: CGFloat(140))
            y += logoH
            let bizTopY = y + (logoH > 0 ? CGFloat(6) : 0)

            var bizLines: [String] = []
            let bizName = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bizName.isEmpty { bizLines.append(bizName) }

            if let a = businessAddress, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let addr = a.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                var streetPart = addr
                var remainder = ""
                if let lastDot = addr.lastIndex(of: ".") {
                    let afterDot = addr.index(after: lastDot)
                    streetPart = String(addr[..<afterDot]).trimmingCharacters(in: .whitespaces)
                    remainder  = String(addr[afterDot...]).trimmingCharacters(in: .whitespaces)
                }
                if !streetPart.isEmpty { bizLines.append(streetPart) }

                let rem = remainder
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",."))

                let re = try? NSRegularExpression(pattern: #"\b([A-Z]{2})\s+(\d{5}(?:-\d{4})?)\b"#, options: [])
                var cszLine: String? = nil
                if let re, let m = re.firstMatch(in: rem, options: [], range: NSRange(location: 0, length: (rem as NSString).length)) {
                    let ns = rem as NSString
                    let state = ns.substring(with: m.range(at: 1))
                    let zip   = ns.substring(with: m.range(at: 2))
                    let cityRaw = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                    let city = cityRaw.trimmingCharacters(in: CharacterSet(charactersIn: ",."))
                    if !city.isEmpty {
                        cszLine = "\(city), \(state) \(zip)"
                    } else {
                        cszLine = rem
                    }
                } else {
                    cszLine = rem
                }
                if let csz = cszLine, !csz.isEmpty { bizLines.append(csz) }
            }
            if let p = businessPhone, !p.isEmpty { bizLines.append(formatPhoneNumber(p)) }

            y = bizTopY
            y += drawMultiline(bizLines.joined(separator: "\n"),
                               at: CGPoint(x: leftX, y: y),
                               width: colW,
                               font: body,
                               lineSpacing: CGFloat(2))
            let bizBottomY = y

            // Meta (right side)
            let invTop = margin
            let title = isQuote ? "QUOTE" : "INVOICE"
            let titleH = draw(title, at: CGPoint(x: rightX, y: invTop), font: h1, color: brandBlue)
            g.setFillColor(brandOrange.cgColor)
            g.fill(CGRect(x: rightX, y: invTop + titleH + CGFloat(4), width: CGFloat(96), height: CGFloat(3)))

            var ry = invTop + titleH + CGFloat(14)
            let df = DateFormatter(); df.dateStyle = .medium
            let invNum = number > 0 ? "#\(number)" : "—"
            ry += draw("Number:", at: CGPoint(x: rightX, y: ry), font: h2)
            ry += draw(invNum, at: CGPoint(x: rightX + CGFloat(90), y: ry - CGFloat(18)), font: body)

            if let d = issueDate {
                ry += draw("Date:", at: CGPoint(x: rightX, y: ry), font: h2)
                ry += draw(df.string(from: d), at: CGPoint(x: rightX + CGFloat(90), y: ry - CGFloat(18)), font: body)
            }

            // Bill To
            let billY = ry
            _ = draw("Bill To", at: CGPoint(x: rightX, y: billY), font: h2)
            var by = billY + CGFloat(18)

            var custLines: [String] = []
            let nameLine = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nameLine.isEmpty { custLines.append(nameLine) }

            if let a = customerAddress, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var normalized = a.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
                normalized = normalized.replacingOccurrences(of: "St. ", with: "St., ")
                normalized = normalized.replacingOccurrences(of: "St ", with: "St., ")
                normalized = normalized.replacingOccurrences(of: " Suite #", with: ", Suite #")
                normalized = normalized.replacingOccurrences(of: " Suite ", with: ", Suite ")
                normalized = normalized.replacingOccurrences(of: " Ste. ", with: ", Ste. ")
                normalized = normalized.replacingOccurrences(of: " Ste ", with: ", Ste ")
                normalized = normalized.replacingOccurrences(of: #"(Suite\s+#?\d+)\b"#, with: "$1,", options: .regularExpression)
                normalized = normalized.replacingOccurrences(of: #"(Ste\.?\s+\d+)\b"#, with: "$1,", options: .regularExpression)

                let parts = normalized
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                    .filter { !$0.isEmpty }

                func cleaned(_ s: String) -> String {
                    s.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if parts.count >= 3 {
                    let street = cleaned(String(parts[0]))
                    let suite  = cleaned(String(parts[1]))
                    let cszLine = cleaned(parts.dropFirst(2).joined(separator: ", "))
                    if !street.isEmpty { custLines.append(street) }
                    if !suite.isEmpty { custLines.append(suite) }
                    if !cszLine.isEmpty { custLines.append(cszLine) }
                } else if parts.count == 2 {
                    let street = cleaned(String(parts[0]))
                    let cszLine = cleaned(String(parts[1]))
                    if !street.isEmpty { custLines.append(street) }
                    if !cszLine.isEmpty { custLines.append(cszLine) }
                } else if parts.count == 1 {
                    let only = cleaned(String(parts[0]))
                    if !only.isEmpty { custLines.append(only) }
                }
            }

            if let p = customerPhone, !p.isEmpty {
                custLines.append("Phone: \(formatPhoneNumber(p))")
            }

            by += drawMultiline(custLines.joined(separator: "\n"),
                                at: CGPoint(x: rightX, y: by),
                                width: colW,
                                font: body,
                                lineSpacing: CGFloat(2))

            // Divider
            let tableTop = max(by, bizBottomY) + CGFloat(12)
            g.setStrokeColor(hairline); g.setLineWidth(CGFloat(0.5))
            g.move(to: CGPoint(x: margin, y: tableTop))
            g.addLine(to: CGPoint(x: page.width - margin, y: tableTop))
            g.strokePath()

            // ===== Table =====
            var ty = drawTableHeader(g, at: tableTop + CGFloat(4))

            for li in lineItems {
                let qty   = (li["qty"] as? Double) ?? 0
                let desc  = (li["description"] as? String) ?? ""
                let rate  = (li["rate"] as? Double) ?? (li["unitPrice"] as? Double) ?? 0
                let amount = (li["amount"] as? Double) ?? (qty * rate)
                let notes = (li["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                let descH = measureText(desc, width: descWidth, font: body)
                var notesH: CGFloat = 0
                if let notes, !notes.isEmpty {
                    notesH = measureText(notes, width: descWidth, font: italic) + CGFloat(2)
                }
                let rowHeight = descH + notesH + CGFloat(6)

                // Check if this row fits on the current page
                if ty + rowHeight > pageBottom {
                    // Draw footer on current page
                    drawFooter(g)

                    // Start new page
                    ctx.beginPage()
                    pageNum += 1
                    let newG = UIGraphicsGetCurrentContext()!

                    // Continuation header
                    let contY = drawContinuationHeader(newG, pageNum: pageNum)
                    ty = drawTableHeader(newG, at: contY)
                }

                let currentG = UIGraphicsGetCurrentContext()!

                // Alternating stripe
                if row % 2 == 1 {
                    currentG.setFillColor(stripe.cgColor)
                    currentG.fill(CGRect(x: margin, y: ty - CGFloat(1), width: page.width - margin*2, height: rowHeight + CGFloat(2)))
                }

                _ = draw(qty == floor(qty) ? String(Int(qty)) : String(format: "%.2f", qty),
                         at: CGPoint(x: qtyX, y: ty), font: body)

                _ = drawMultiline(desc,
                                  at: CGPoint(x: descX, y: ty),
                                  width: descWidth,
                                  font: body)

                if let notes, !notes.isEmpty {
                    _ = drawMultiline(notes,
                                      at: CGPoint(x: descX, y: ty + descH + CGFloat(2)),
                                      width: descWidth,
                                      font: italic)
                }

                _ = draw(String(format: "$%.2f", rate),
                         at: CGPoint(x: rateX, y: ty),
                         font: body, width: CGFloat(90), align: .right)
                _ = draw(String(format: "$%.2f", amount),
                         at: CGPoint(x: amtX,  y: ty),
                         font: body, width: CGFloat(70), align: .right)

                ty += rowHeight
                row += 1
            }

            // ===== Totals & Notes =====
            // Check if totals box fits on current page (need ~130pt)
            let totalsNeeded: CGFloat = 130
            if ty + totalsNeeded > pageBottom {
                drawFooter(UIGraphicsGetCurrentContext()!)
                ctx.beginPage()
                pageNum += 1
                let newG = UIGraphicsGetCurrentContext()!
                ty = drawContinuationHeader(newG, pageNum: pageNum)
            }

            let totalsTop = ty + CGFloat(6)
            let boxW: CGFloat = 260
            let boxX = page.width - margin - boxW
            let inner: CGFloat = 16
            let totalBoxG = UIGraphicsGetCurrentContext()!
            let rect = CGRect(x: boxX, y: totalsTop, width: boxW, height: CGFloat(110))
            totalBoxG.setFillColor(UIColor(white: 0.985, alpha: 1).cgColor)
            totalBoxG.fill(rect)
            totalBoxG.setStrokeColor(hairline); totalBoxG.setLineWidth(CGFloat(0.75)); totalBoxG.stroke(rect)

            var sumY = totalsTop + inner
            let totalWidth = boxW - inner*2
            let valW: CGFloat = 102
            let keyW: CGFloat = totalWidth - valW - CGFloat(8)

            sumY += drawKeyValSplit("Subtotal", String(format: "$%.2f", subtotal),
                                    at: CGPoint(x: boxX+inner, y: sumY),
                                    keyFont: body, valFont: body,
                                    spacing: CGFloat(6), labelWidth: keyW, valueWidth: valW)

            sumY += drawKeyValSplit("Sales Tax", String(format: "$%.2f", tax),
                                    at: CGPoint(x: boxX+inner, y: sumY),
                                    keyFont: body, valFont: body,
                                    spacing: CGFloat(6), labelWidth: keyW, valueWidth: valW)

            let totalRowTop = sumY
            totalBoxG.setFillColor(brandOrange.withAlphaComponent(0.12).cgColor)
            totalBoxG.fill(CGRect(x: boxX + CGFloat(8), y: totalRowTop - CGFloat(4), width: boxW - CGFloat(16), height: CGFloat(28)))

            _ = drawKeyValSplit("Total", String(format: "$%.2f", total),
                                at: CGPoint(x: boxX+inner, y: totalRowTop),
                                keyFont: h2, valFont: h2,
                                spacing: CGFloat(8), labelWidth: keyW, valueWidth: valW)

            // Notes — left of the totals box
            if let n = invoiceNotes, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let gutter: CGFloat = 12
                var ny = totalsTop
                _ = draw("Notes", at: CGPoint(x: margin, y: ny), font: h2)
                ny += CGFloat(14)
                let notesWidth = boxX - margin - gutter
                _ = drawMultiline(n,
                                  at: CGPoint(x: margin, y: ny),
                                  width: notesWidth,
                                  font: body)
            }

            // Footer on last page
            drawFooter(UIGraphicsGetCurrentContext()!)
        }
    }
}
