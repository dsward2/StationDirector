import Foundation

enum SpokenTime {
    /// "4:15 PM", or "5 o'clock" on the hour.
    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = (c.hour! + 11) % 12 + 1
        let suffix = c.hour! < 12 ? "AM" : "PM"
        return c.minute! == 0 ? "\(h) o'clock" : String(format: "%d:%02d %@", h, c.minute!, suffix)
    }

    /// The hour for a top-of-hour ID: "5 o'clock", or the half past it rounds to.
    static func hour(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let rounded = c.minute! >= 30 ? c.hour! + 1 : c.hour!
        return "\((rounded + 11) % 12 + 1) o'clock"
    }

    /// Rewrites clock times ("4:09", "4:09 PM", "4:09 p.m.") as words, so the
    /// speech synthesizer doesn't read "4:09" as a duration ("4 minutes and
    /// 9 seconds"). Applied to every line just before it is spoken, which
    /// covers templates, model-written lines and headlines alike.
    static func speakable(_ text: String) -> String {
        // "p.m." keeps its final dot as the sentence end unless more of the
        // sentence follows in lowercase.
        let pattern = #"\b([01]?\d|2[0-3]):([0-5]\d)(?:\s*([AaPp])(?:\.\s?[Mm]\.(?=\s+[a-z])|\.?\s?[Mm]\b))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let hour = Int(ns.substring(with: match.range(at: 1)))!
            let minute = Int(ns.substring(with: match.range(at: 2)))!
            var meridiem: String?
            if match.range(at: 3).location != NSNotFound {
                meridiem = ns.substring(with: match.range(at: 3)).uppercased() + " M"
            } else if hour > 12 || hour == 0 {
                meridiem = hour < 12 ? "A M" : "P M"
            }
            var words = [number((hour + 11) % 12 + 1)]
            if minute == 0 {
                if meridiem == nil { words.append("o'clock") }
            } else if minute < 10 {
                words += ["oh", number(minute)]
            } else {
                words.append(number(minute))
            }
            if let meridiem { words.append(meridiem) }
            result += words.joined(separator: " ")
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                               "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                               "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty"]

    /// 0–59 as words.
    private static func number(_ n: Int) -> String {
        if n < 20 { return ones[n] }
        return n % 10 == 0 ? tens[n / 10] : "\(tens[n / 10])-\(ones[n % 10])"
    }
}
