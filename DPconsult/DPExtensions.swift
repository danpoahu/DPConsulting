//
//  DPExtensions.swift
//  DPconsult
//
//  Centralized shared extensions used across the app.
//

import Foundation

extension Double {
    /// Formats the double as a USD currency string with two fraction digits.
    /// Example: 1234.5 -> "$1,234.50"
    func currencyString() -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "$%.2f", self)
    }
}
