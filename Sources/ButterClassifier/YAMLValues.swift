import Foundation

enum YAMLValues {
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func doubleArray(_ value: Any?) -> [Double] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { double($0) }
    }
}
