import Foundation
import FoundationModels

/// Everything the announcer is allowed to say. The model only does wording.
struct Facts {
    var stationName: String
    var slogan: String
    var time: String                    // "4:15"
    var city: String?
    var temperatureF: Int?
    var conditions: String?
    var justPlayed: (title: String, artist: String)?
    var upNext: (title: String, artist: String)?

    var listing: String {
        var lines = ["Station name: \(stationName)", "Slogan: \(slogan)", "Time: \(time)"]
        if let city { lines.append("City: \(city)") }
        if let temperatureF { lines.append("Temperature: \(temperatureF) degrees") }
        if let conditions { lines.append("Conditions: \(conditions)") }
        if let p = justPlayed { lines.append("Song that is ending: \"\(p.title)\" by \(p.artist)") }
        if let n = upNext { lines.append("Next song: \"\(n.title)\" by \(n.artist)") }
        return lines.joined(separator: "\n")
    }
}

@Generable
struct AnnouncerLine {
    @Guide(description: "The words the announcer speaks, as plain text")
    var text: String
}

/// Announcer copy: templates always, Foundation Models when enabled and
/// available. A model line is used only if it passes `grounded(_:in:)`.
final class Copywriter {
    private let useAI: Bool
    private var rotation = 0

    init(useAI: Bool) {
        let available = SystemLanguageModel.default.availability == .available
        self.useAI = useAI && available
        if useAI && !available {
            Log.info("copy: Foundation Models unavailable (\(SystemLanguageModel.default.availability)); templates only")
        }
    }

    // MARK: Lines

    func talkOver(_ f: Facts) async -> String {
        rotation += 1
        let template: String
        let weather = f.temperatureF.map { " \($0) degrees" + (f.conditions.map { " and \($0.lowercased())" } ?? "") + "." } ?? ""
        switch (rotation % 3, f.justPlayed, f.upNext) {
        case (_, let p?, let n?):
            template = "That was \(p.title) by \(p.artist). Coming up, \(n.title) from \(n.artist), on \(f.stationName)."
        case (0, let p?, nil):
            template = "\(p.title), \(p.artist). It's \(f.time) on \(f.stationName)."
        case (1, let p?, nil):
            template = "That was \(p.artist), with \(p.title). It's \(f.time), and\(weather.isEmpty ? " this is \(f.stationName)." : weather)"
        default:
            template = "\(f.stationName). It's \(f.time)."
        }
        return await polish(template: template, facts: f, task: """
            Write what the DJ says over the last seconds of the ending song, in one or two complete, \
            conversational sentences (at most 22 words in all). Name the ending song and its artist, then add \
            one of: the time, the temperature, or the station name. If a next song is listed, introduce it too. \
            Style example with made-up facts: "That was Morning Rain from the Blue Lanterns. It's 9:40, \
            and sixty-one degrees out there on Radio Example."
            """)
    }

    func stationID(_ f: Facts) async -> String {
        let template = "You're listening to \(f.stationName), \(f.slogan). It's \(f.time)."
        return await polish(template: template, facts: f, task: """
            Write a short station identification in one or two complete, conversational sentences \
            (at most 20 words), using the station name, the slogan and the time.
            """)
    }

    func topOfHour(_ f: Facts, hour: String, headlines: [Headline]) async -> String {
        var parts = ["It's \(hour), and this is \(f.stationName), \(f.slogan)."]
        if let t = f.temperatureF {
            let place = f.city.map { " in \($0)" } ?? ""
            parts.append("Right now it's \(t) degrees" + (f.conditions.map { " and \($0.lowercased())" } ?? "") + "\(place).")
        }
        if !headlines.isEmpty {
            parts.append("Here's the news.")
            var previousSource: String?
            for h in headlines {
                // Credit each story's source; "Also from" when it repeats.
                let credit = h.source == previousSource ? "Also from \(h.source):" : "From \(h.source):"
                parts.append("\(credit) \(await radioHeadline(h.title))")
                previousSource = h.source
            }
        }
        parts.append("More music now, on \(f.stationName).")
        return parts.joined(separator: " ")
    }

    func weather(_ f: Facts, periods: [Weather.Period]) -> String {
        guard let first = periods.first else {
            return "The forecast isn't available right now. It's \(f.time) on \(f.stationName)."
        }
        var parts = ["Here's the forecast from the National Weather Service."]
        parts.append("\(first.name): \(Self.spokenUnits(first.detailedForecast))")
        if periods.count > 1 {
            let p = periods[1]
            let hl = p.isDaytime ? "a high near" : "a low around"
            parts.append("\(p.name): \(p.shortForecast.lowercased()), with \(hl) \(p.temperature).")
        }
        if let t = f.temperatureF { parts.append("Right now it's \(t) degrees on \(f.stationName).") }
        return parts.joined(separator: " ")
    }

    /// NWS abbreviations the voices read letter by letter.
    private static func spokenUnits(_ s: String) -> String {
        s.replacingOccurrences(of: " mph", with: " miles an hour")
    }

    // MARK: Model

    /// One-sentence radio copy for an RSS title; the title itself on failure.
    private func radioHeadline(_ headline: String) async -> String {
        let plain = headline.hasSuffix(".") || headline.hasSuffix("?") || headline.hasSuffix("!") ? headline : headline + "."
        guard useAI else { return plain }
        let prompt = """
            Rewrite this news headline as one complete spoken sentence for a radio newscast, the way a \
            newsreader would say it. Keep every name, place and number in it. Do not add names, numbers, \
            places or details that are not in the headline.
            Headline: \(headline)
            """
        guard let line = await generate(prompt), grounded(line, in: headline) else { return plain }
        return line
    }

    private func polish(template: String, facts: Facts, task: String) async -> String {
        guard useAI else { return template }
        let prompt = "\(task)\n\nFacts:\n\(facts.listing)"
        guard let line = await generate(prompt) else { return template }
        guard grounded(line, in: facts.listing), line.split(separator: " ").count <= 30 else {
            Log.info("copy: model line rejected by fact check: \(line)")
            return template
        }
        return line
    }

    private func generate(_ prompt: String) async -> String? {
        let instructions = """
            You are the announcer on a small personal radio station. You write short, warm, natural lines \
            to be read aloud by a speech synthesizer. Use ONLY the facts you are given. Never add trivia, \
            release years, chart positions, album names, band history or opinions about the music. \
            No emoji, hashtags, stage directions or quotation marks.
            """
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let reply = try await session.respond(to: prompt, generating: AnnouncerLine.self)
                    return reply.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    Log.info("copy: model error: \(error)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// The guardrail: every number, and every capitalized word that isn't
    /// starting a sentence, must appear in the source facts. Catches invented
    /// names, places, years and chart claims; lets ordinary wording through.
    func grounded(_ line: String, in source: String) -> Bool {
        let haystack = source.lowercased()
        let words = line.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var sentenceStart = true
        for raw in words {
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            defer { sentenceStart = raw.hasSuffix(".") || raw.hasSuffix("!") || raw.hasSuffix("?") || raw.hasSuffix(":") }
            guard !word.isEmpty else { continue }
            if word.rangeOfCharacter(from: .decimalDigits) != nil {
                for number in word.components(separatedBy: CharacterSet.decimalDigits.inverted) where !number.isEmpty {
                    if !haystack.contains(number) { return false }
                }
                continue
            }
            let isCapitalized = word.first?.isUppercase == true
            if isCapitalized && !sentenceStart && !["I", "I'm", "I'll"].contains(word)
                && !haystack.contains(word.lowercased()) {
                return false
            }
        }
        return true
    }
}
