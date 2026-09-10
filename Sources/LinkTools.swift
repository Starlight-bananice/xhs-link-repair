import Foundation

struct NoteReference: Equatable {
    let id: String
    let original: String
}

enum BatchInput: Equatable {
    case note(NoteReference)
    case shortLink(URL)
}

enum LinkTools {
    private static let notePathPattern = #"(?i)(?:discovery/item|explore|xhsdiscover://item)/(?:discovery\.)?([0-9a-f]{24})"#
    private static let bareIDPattern = #"(?i)(?<![0-9a-f])([0-9a-f]{24})(?![0-9a-f])"#
    private static let webURLPattern = #"https?://[^\s<>\"'，。；、（）()\[\]{}]+"#

    static func extractNoteID(from text: String) -> String? {
        if let id = firstCapture(in: text, pattern: notePathPattern) {
            return id.lowercased()
        }
        return firstCapture(in: text, pattern: bareIDPattern)?.lowercased()
    }

    static func extractNoteIDs(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: bareIDPattern), !text.isEmpty else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
            guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
            let id = String(text[swiftRange]).lowercased()
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    static func extractWebURL(from text: String) -> URL? {
        extractWebURLs(from: text).first
    }

    static func extractWebURLs(from text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: webURLPattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let trailing = CharacterSet(charactersIn: "，。；;、）)]}>！!？?\n\r\t")
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let candidate = String(text[swiftRange])
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: trailing)
            return URL(string: candidate)
        }
    }

    static func extractNoteReferences(from text: String) -> [NoteReference] {
        extractBatchInputs(from: text).compactMap {
            if case .note(let reference) = $0 { return reference }
            return nil
        }
    }

    static func extractBatchInputs(from text: String) -> [BatchInput] {
        // 同时扫描 URL 和裸 ID，保留混合粘贴时的首次出现顺序。
        // 整个 URL 先作为一个匹配，避免把主页 ID、签名参数误当成笔记。
        let normalized = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x20;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&#32;", with: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let pattern = "\(webURLPattern)|xhsdiscover://item/(?:discovery\\.)?[0-9a-f]{24}|\(bareIDPattern)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>()
        var inputs: [BatchInput] = []
        for match in regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            guard let range = Range(match.range, in: normalized) else { continue }
            let token = String(normalized[range])
            if let url = extractWebURL(from: token) {
                if isOfficialShortLink(url), !url.path.isEmpty, url.path != "/" {
                    if seen.insert("short:\(url.absoluteString)").inserted { inputs.append(.shortLink(url)) }
                } else if let id = noteID(in: url), seen.insert("note:\(id)").inserted {
                    inputs.append(.note(NoteReference(id: id, original: url.absoluteString)))
                }
            } else if let id = extractNoteID(from: token), seen.insert("note:\(id)").inserted {
                inputs.append(.note(NoteReference(id: id, original: token)))
            }
        }
        return inputs
    }

    static func isOfficialShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["xhslink.com", "www.xhslink.com", "xhslink.cn", "www.xhslink.cn"].contains(host)
    }

    static func noteID(in url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com") else { return nil }
        // 只认笔记路径；主页 URL 的用户 ID 或查询参数中的笔记 ID 都不算。
        return firstCapture(in: url.path, pattern: #"(?i)^/(?:explore|discovery/item)/(?:discovery\.)?([0-9a-f]{24})/?$"#)?.lowercased()
    }

    static func isProfileURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com") else { return false }
        return url.path.lowercased().hasPrefix("/user/profile/")
    }

    static func isShareURL(_ url: URL, for expectedNoteID: String) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if isOfficialShortLink(url) { return url.path != "/" && !url.path.isEmpty }
        return noteID(in: url) == expectedNoteID.lowercased() && isSignedXiaohongshuLink(url)
    }

    static func isSignedXiaohongshuLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.queryItems?.contains(where: {
            $0.name == "xsec_token" && !($0.value ?? "").isEmpty
        }) == true
    }

    static func compactShareURL(_ url: URL) -> URL {
        guard let id = noteID(in: url),
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "xsec_token" && !($0.value ?? "").isEmpty })?.value else {
            return url
        }
        var result = URLComponents()
        result.scheme = "https"
        result.host = "www.xiaohongshu.com"
        result.path = "/explore/\(id)"
        result.queryItems = [
            URLQueryItem(name: "xsec_token", value: token),
            URLQueryItem(name: "xsec_source", value: "app_share")
        ]
        // 保留 token 中的加号含义，避免查询参数解析器将它当作空格。
        result.percentEncodedQuery = result.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return result.url ?? url
    }

    static func deepLink(for noteID: String) -> URL? {
        URL(string: "xhsdiscover://item/\(noteID)")
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
