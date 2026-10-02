import Foundation

public enum Stats {
    public static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample standard deviation. Zero for fewer than two values.
    public static func std(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)).squareRoot()
    }
}
