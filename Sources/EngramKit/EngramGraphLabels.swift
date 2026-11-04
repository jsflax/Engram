import Foundation

/// Engram's existing graph label algorithm, extracted from GraphModels.swift for shared graph hosts.
public enum EngramGraphLabels {
    public static func label(content: String, topic: String) -> String {
        let maxLen = 30
        if let headerRange = content.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
            let title = content[headerRange.upperBound...].prefix(while: { $0 != "\n" })
            return truncate(String(title), to: maxLen)
        }
        if content.hasPrefix("**"), let end = content.dropFirst(2).range(of: "**") {
            let title = content[content.index(content.startIndex, offsetBy: 2)..<end.lowerBound]
            return truncate(String(title), to: maxLen)
        }
        if let colon = content.firstIndex(of: ":"),
           content.distance(from: content.startIndex, to: colon) < maxLen {
            return String(content[..<colon])
        }
        let firstLine = String(content.prefix(while: { $0 != "\n" }))
        if firstLine.count <= maxLen { return firstLine }
        if topic != "general" {
            let combined = "\(topic): \(firstLine)"
            if combined.count <= maxLen { return combined }
            if topic.count + 2 + 5 <= maxLen {
                return "\(topic): \(truncate(firstLine, to: maxLen - topic.count - 2))"
            }
            let prefix = truncate(topic, to: 12)
            return "\(prefix): \(truncate(firstLine, to: maxLen - prefix.count - 2))"
        }
        return truncate(firstLine, to: maxLen)
    }

    public static func truncate(_ text: String, to maximum: Int) -> String {
        guard maximum > 0 else { return "" }
        if text.count <= maximum { return text }
        return String(text.prefix(maximum - 1)) + "…"
    }
}
