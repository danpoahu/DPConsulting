import Foundation

/// A protocol for objects that can be represented as a row in a journal entry CSV export.
public protocol JournalEntryRepresentable {
    var dateString: String { get }
    var account: String { get }
    var descriptionText: String { get }
    var debit: String { get }
    var credit: String { get }
}

/// Exports journal entries to CSV format with proper escaping per RFC 4180.
public struct JournalCSVExporter {
    public init() {}

    /// Creates CSV data from an array of journal entry objects.
    /// - Parameter entries: Array of objects conforming to JournalEntryRepresentable
    /// - Returns: UTF-8 encoded CSV data with CRLF line endings
    public func makeCSV<T: JournalEntryRepresentable>(entries: [T]) -> Data {
        let headers = ["Date", "Account", "Description", "Debit", "Credit"]
        let rows = entries.map { entry in
            [
                entry.dateString,
                entry.account,
                entry.descriptionText,
                entry.debit,
                entry.credit
            ]
        }
        return makeCSV(headers: headers, rows: rows)
    }
    
    /// Creates CSV data from headers and rows.
    /// - Parameters:
    ///   - headers: Array of column header strings
    ///   - rows: Array of rows, each row being an array of string values
    /// - Returns: UTF-8 encoded CSV data with CRLF line endings
    public func makeCSV(headers: [String], rows: [[String]]) -> Data {
        var lines: [String] = []
        lines.append(headers.map { escapeCSV($0) }.joined(separator: ","))
        for row in rows {
            lines.append(row.map { escapeCSV($0) }.joined(separator: ","))
        }
        let csvString = lines.joined(separator: "\r\n") + "\r\n"
        return Data(csvString.utf8)
    }
    
    /// Escapes a CSV field value according to RFC 4180.
    /// Fields containing comma, double-quote, CR or LF are enclosed in double quotes,
    /// and embedded double quotes are doubled.
    /// - Parameter value: The string to escape
    /// - Returns: Properly escaped CSV field value
    private func escapeCSV(_ value: String) -> String {
        let mustQuote = value.contains(",") || value.contains("\"") || value.contains("\r") || value.contains("\n")
        if mustQuote {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        } else {
            return value
        }
    }
}

/*
 Usage Examples:
 
 1. Using JournalEntryRepresentable protocol:
 
 struct JournalEntry: JournalEntryRepresentable {
     var dateString: String
     var account: String
     var descriptionText: String
     var debit: String
     var credit: String
 }
 
 let entries: [JournalEntry] = [
     JournalEntry(dateString: "2026-01-31", account: "Cash", descriptionText: "Sale", debit: "100.00", credit: ""),
     JournalEntry(dateString: "2026-01-31", account: "Revenue", descriptionText: "Sale", debit: "", credit: "100.00")
 ]
 
 let exporter = JournalCSVExporter()
 let csvData = exporter.makeCSV(entries: entries)
 try csvData.write(to: fileURL)
 
 2. Using headers and rows directly:
 
 let exporter = JournalCSVExporter()
 let csvData = exporter.makeCSV(
     headers: ["Date", "Account", "Amount"],
     rows: [
         ["2026-01-31", "Cash", "100.00"],
         ["2026-01-31", "Sales", "100.00"]
     ]
 )
 try csvData.write(to: fileURL)
 */



