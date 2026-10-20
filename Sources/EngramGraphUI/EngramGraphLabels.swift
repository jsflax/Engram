import Foundation

public func engramGraphLabel(content: String, topic: String) -> String {
    let maxLen = 30
    if let headerRange = content.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
        let title = content[headerRange.upperBound...].prefix(while: { $0 != "\n" })
        return engramGraphTruncateLabel(String(title), to: maxLen)
    }
    if content.hasPrefix("**"), let end = content.dropFirst(2).range(of: "**") {
        let title = content[content.index(content.startIndex, offsetBy: 2)..<end.lowerBound]
        return engramGraphTruncateLabel(String(title), to: maxLen)
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
        // Topic fits — truncate content only
        if topic.count + 2 + 5 <= maxLen {
            return "\(topic): \(engramGraphTruncateLabel(firstLine, to: maxLen - topic.count - 2))"
        }
        // Topic too long — truncate both
        let prefix = engramGraphTruncateLabel(topic, to: 12)
        return "\(prefix): \(engramGraphTruncateLabel(firstLine, to: maxLen - prefix.count - 2))"
    }
    return engramGraphTruncateLabel(firstLine, to: maxLen)
}

public func engramGraphTruncateLabel(_ text: String, to maxLen: Int) -> String {
    guard maxLen > 0 else { return "" }
    if text.count <= maxLen { return text }
    return String(text.prefix(maxLen - 1)) + "…"
}

