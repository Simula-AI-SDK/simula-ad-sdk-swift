import CoreGraphics
import Foundation

/// A parsed width value for a native ad slot. Mirrors the Kotlin/Android SDK's dimension handling so
/// the two platforms interpret `width` identically.
///
/// Produced by ``parseDimension(_:)`` from a flexible public input (`nil`, a string like `"80%"` /
/// `"320px"` / `"300"`, or a number). ``clampMinWidth(_:)`` enforces the slot's minimum.
enum ParsedDimension: Equatable {
    /// Fill the parent (100%) — the default.
    case fill
    /// A fraction of the parent width, `0 < f <= 1`.
    case percentage(Float)
    /// A fixed point value.
    case pixels(CGFloat)

    /// Raises a `.pixels` value below `minWidth` up to it. `.fill` and `.percentage` pass through
    /// unchanged — percentages are clamped at layout time, where the parent width is known (a
    /// `.frame(width:).frame(minWidth:)` combination does *not* enforce a minimum in SwiftUI).
    func clampMinWidth(_ minWidth: CGFloat) -> ParsedDimension {
        switch self {
        case .pixels(let value): return .pixels(max(value, minWidth))
        case .fill, .percentage: return self
        }
    }
}

/// Parses a flexible `width` input into a ``ParsedDimension``. Accepts `nil`, strings (`"80%"`,
/// `"320px"` (case-insensitive), `"300"`, `"auto"`, `""`), and numbers (Int / Double / Float /
/// CGFloat). Anything invalid — negatives, zero, out-of-range percentages, booleans, arrays, garbage
/// strings — falls back to ``ParsedDimension/fill``. Mirrors the Android SDK's `parseDimension`.
func parseDimension(_ input: Any?) -> ParsedDimension {
    guard let input else { return .fill }

    // Bool bridges to NSNumber, so it must be rejected before the numeric path — `true`/`false`
    // are not sizes.
    if input is Bool { return .fill }

    if let string = input as? String {
        return parseDimensionString(string)
    }

    // Int / Double / Float / CGFloat all bridge to NSNumber (Bool already excluded above).
    if let number = input as? NSNumber {
        return parseDimensionNumber(number.doubleValue)
    }

    return .fill
}

private func parseDimensionString(_ raw: String) -> ParsedDimension {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .fill }

    let lower = trimmed.lowercased()
    if lower == "auto" { return .fill }

    if lower.hasSuffix("%") {
        let body = String(lower.dropLast()).trimmingCharacters(in: .whitespaces)
        if let n = Double(body), n > 0, n <= 100 { return .percentage(Float(n / 100)) }
        return .fill
    }

    if lower.hasSuffix("px") {
        let body = String(lower.dropLast(2)).trimmingCharacters(in: .whitespaces)
        if let n = Double(body), n > 0 { return .pixels(CGFloat(n)) }
        return .fill
    }

    if let n = Double(trimmed), n > 0 { return .pixels(CGFloat(n)) }

    return .fill
}

private func parseDimensionNumber(_ value: Double) -> ParsedDimension {
    if value > 0, value < 1 { return .percentage(Float(value)) }
    if value >= 1 { return .pixels(CGFloat(value)) }
    return .fill
}
