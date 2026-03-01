//
//  CSVExporter.swift
//
//  Created by CSV Exporter.
//
//  This struct provides functionality to export CSV data conforming to RFC 4180.
//  Usage:
//      let exporter = CSVExporter()
//      let csvData = exporter.makeCSV(headers: ["Name", "Age"], rows: [["John Doe", "30"], ["Jane, Smith", "25"]])
//      // csvData contains UTF-8 encoded CSV data with proper escaping and CRLF line endings.
//So th

import Foundation

public struct CSVExporter {
    
    public init() { }
    
    /// Creates a CSV document as UTF-8 encoded Data from the given headers and rows.
    /// - Parameters:
    ///   - headers: An array of header strings.
    ///   - rows: An array of rows, each row being an array of column values as strings.
    /// - Returns: UTF-8 encoded Data representing the CSV document.
    public func makeCSV(headers: [String], rows: [[String]]) -> Data {
        var lines: [String] = []
        lines.append(headers.map { escape($0) }.joined(separator: ","))
        for row in rows {
            lines.append(row.map { escape($0) }.joined(separator: ","))
        }
        let csvString = lines.joined(separator: "\r\n") + "\r\n"
        return Data(csvString.utf8)
    }
    
    /// Escapes a single CSV field value according to RFC 4180.
    /// Fields containing comma, double-quote, CR or LF are enclosed in double quotes,
    /// and embedded double quotes are doubled.
    /// - Parameter value: The string value to escape.
    /// - Returns: The escaped string suitable for CSV.
    private func escape(_ value: String) -> String {
        let mustQuote = value.contains(",") || value.contains("\"") || value.contains("\r") || value.contains("\n")
        if mustQuote {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        } else {
            return value
        }
    }
}
