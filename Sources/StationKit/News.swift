import Foundation

/// A headline and the name of the feed it came from, for on-air attribution.
public struct Headline: Equatable, Sendable {
    public let title: String
    public let source: String
}

/// Headlines from RSS 2.0 / Atom feeds, round-robin across feeds so one
/// source doesn't take every slot.
///
/// A feed entry is a URL, optionally preceded by the name to credit on air:
/// `NPR | https://feeds.npr.org/1001/rss.xml`. Without a name, the feed's own
/// title is shortened ("NPR Topics: News" → "NPR").
enum News {
    static func headlines(feeds: [String], count: Int) async -> [Headline] {
        var perFeed: [[Headline]] = []
        for entry in feeds {
            let (name, urlString) = parseEntry(entry)
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue("AntennaHead-StationDirector", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                let feed = FeedTitles.parse(data)
                let source = name ?? shortName(feed.channelTitle) ?? url.host() ?? "the wire"
                perFeed.append(feed.titles.map { Headline(title: $0, source: source) })
            } catch {
                Log.info("news: \(urlString): \(error.localizedDescription)")
            }
        }
        var out: [Headline] = []
        var seen = Set<String>()
        var index = 0
        while out.count < count, perFeed.contains(where: { index < $0.count }) {
            for headlines in perFeed where index < headlines.count && out.count < count {
                let headline = headlines[index]
                if seen.insert(headline.title.lowercased()).inserted { out.append(headline) }
            }
            index += 1
        }
        return out
    }

    /// "NPR | https://…" → ("NPR", "https://…"); a bare URL has no name.
    static func parseEntry(_ entry: String) -> (name: String?, url: String) {
        let parts = entry.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[0].isEmpty { return (parts[0], parts[1]) }
        return (nil, entry.trimmingCharacters(in: .whitespaces))
    }

    /// A feed title shortened to something sayable: the part before ":",
    /// " - ", " | " or " — ", without trailing "Topics", "News", "Headlines"….
    static func shortName(_ title: String?) -> String? {
        guard var name = title?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        for separator in [":", " - ", " | ", " — ", " – "] {
            if let r = name.range(of: separator) { name = String(name[..<r.lowerBound]) }
        }
        let filler: Set<String> = ["topics", "news", "headlines", "rss", "feed", "latest", "top", "stories"]
        var words = name.split(separator: " ").map(String.init)
        while words.count > 1, let last = words.last, filler.contains(last.lowercased()) { words.removeLast() }
        name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// Collects `<item><title>` (RSS) and `<entry><title>` (Atom) text.
private final class FeedTitles: NSObject, XMLParserDelegate {
    private var titles: [String] = []
    /// The feed's own `<title>` (the first one outside any item).
    private var channelTitle: String?
    private var inItem = false
    private var inTitle = false
    private var text = ""

    static func parse(_ data: Data) -> (titles: [String], channelTitle: String?) {
        let delegate = FeedTitles()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.titles, delegate.channelTitle)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" || name == "entry" { inItem = true }
        if name == "title" && (inItem || channelTitle == nil) { inTitle = true; text = "" }
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
            if inItem {
                if !title.isEmpty { titles.append(title) }
            } else if channelTitle == nil {
                channelTitle = title
            }
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
