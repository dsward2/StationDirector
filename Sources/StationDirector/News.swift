import Foundation

/// Headlines from RSS 2.0 / Atom feeds, round-robin across feeds so one
/// source doesn't take every slot.
enum News {
    static func headlines(feeds: [String], count: Int) async -> [String] {
        var perFeed: [[String]] = []
        for feed in feeds {
            guard let url = URL(string: feed) else { continue }
            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue("AntennaHead-StationDirector", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                perFeed.append(FeedTitles.parse(data))
            } catch {
                Log.info("news: \(feed): \(error.localizedDescription)")
            }
        }
        var out: [String] = []
        var seen = Set<String>()
        var index = 0
        while out.count < count, perFeed.contains(where: { index < $0.count }) {
            for titles in perFeed where index < titles.count && out.count < count {
                let title = titles[index]
                if seen.insert(title.lowercased()).inserted { out.append(title) }
            }
            index += 1
        }
        return out
    }
}

/// Collects `<item><title>` (RSS) and `<entry><title>` (Atom) text.
private final class FeedTitles: NSObject, XMLParserDelegate {
    private var titles: [String] = []
    private var inItem = false
    private var inTitle = false
    private var text = ""

    static func parse(_ data: Data) -> [String] {
        let delegate = FeedTitles()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.titles
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" || name == "entry" { inItem = true }
        if inItem && name == "title" { inTitle = true; text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if inTitle, let s = String(data: block, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "title" && inTitle {
            inTitle = false
            let title = Self.decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titles.append(title) }
        }
        if name == "item" || name == "entry" { inItem = false }
    }

    /// Some feeds double-encode ("&amp;amp;", "&amp;#x27;"); XMLParser undoes
    /// one level, this undoes the rest.
    private static func decodeEntities(_ s: String) -> String {
        var out = s
        for _ in 0..<2 {
            out = out.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            while let r = out.range(of: "&#(x[0-9a-fA-F]+|[0-9]+);", options: .regularExpression) {
                let body = out[r].dropFirst(2).dropLast()
                let value = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                out.replaceSubrange(r, with: value.flatMap(Unicode.Scalar.init).map(String.init) ?? "")
            }
        }
        return out
    }
}
