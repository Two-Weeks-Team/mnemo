// Parse the recall model's native-function-call output into a typed call
// against `RecallFunctionContract`. Models are messy — they wrap JSON in
// ```fences```, prefix it with prose, use `<tool_call>` tags, or name the
// argument bag `arguments` / `parameters` / `args`. This parser is tolerant of
// all of that and, when it genuinely can't find a call, returns `.unparseable`
// so the caller can fall back to treating the raw text as a low-confidence
// direct answer. (This is the "parser for malformed output" the plan §2.3 and
// the He Was Socrates FunctionCallOrchestrator pattern call for.)
//
// Phase 3: the *generation* side — running Gemma 4 to produce this text — needs
// MLX (Apple-Silicon-only, Xcode, ~4 GB weights) and lives in a separate
// integration target / the app layer (mirroring He Was Socrates's
// `#if canImport(MLXLLM)` split). This parser is the pure, testable half and
// ships now; see `FunctionCallGenerating` for the seam.

import Foundation

/// A recall-turn function call, decoded from the model's output.
public enum RecallFunctionCall: Sendable, Equatable {
    case recallEvents(query: String, timeRange: DateInterval?)
    case summarizePeriod(timeRange: DateInterval)
    case findEntityMentions(entity: String)
    case setReminder(when: Date, what: String, surfaceModality: ExpressionModality?)
    case flagForHuman(reason: String, resourceClass: String)
    /// Nothing parseable — the caller should fall back (treat `rawText` as a
    /// direct answer with low confidence).
    case unparseable(rawText: String)
}

public enum FunctionCallParser {

    /// Parse the model's raw text. Never throws — failure is `.unparseable`.
    public static func parse(_ rawModelText: String) -> RecallFunctionCall {
        let cleaned = stripWrappers(rawModelText)
        guard let obj = firstJSONObject(in: cleaned) else {
            return .unparseable(rawText: rawModelText)
        }
        let name = (stringValue(obj, keys: ["name", "function", "tool", "tool_name"]) ?? "").lowercased()
        let args = dictValue(obj, keys: ["arguments", "parameters", "args", "input"]) ?? obj

        switch name {
        case "recall_events":
            let q = stringValue(args, keys: ["query", "question", "q"]) ?? ""
            guard !q.isEmpty else { return .unparseable(rawText: rawModelText) }
            return .recallEvents(query: q, timeRange: rangeValue(args, keys: ["time_range", "range", "when"]))

        case "summarize_period":
            guard let range = rangeValue(args, keys: ["time_range", "range", "span", "period"]) else {
                return .unparseable(rawText: rawModelText)
            }
            return .summarizePeriod(timeRange: range)

        case "find_entity_mentions":
            let e = stringValue(args, keys: ["entity", "name", "subject"]) ?? ""
            guard !e.isEmpty else { return .unparseable(rawText: rawModelText) }
            return .findEntityMentions(entity: e)

        case "set_reminder":
            guard let when = dateValue(args, keys: ["when", "at", "time", "date"]) else {
                return .unparseable(rawText: rawModelText)
            }
            let what = stringValue(args, keys: ["what", "text", "message", "reminder"]) ?? ""
            guard !what.isEmpty else { return .unparseable(rawText: rawModelText) }
            let modality = (stringValue(args, keys: ["surface_modality", "modality", "channel"]))
                .flatMap { ExpressionModality(rawValue: $0.lowercased()) }
            return .setReminder(when: when, what: what, surfaceModality: modality)

        case "flag_for_human":
            let reason = stringValue(args, keys: ["reason", "why", "explanation"]) ?? "out of scope"
            let resource = stringValue(args, keys: ["resource_class", "resource", "who", "refer_to"])
                ?? "a person who can help"
            return .flagForHuman(reason: reason, resourceClass: resource)

        default:
            return .unparseable(rawText: rawModelText)
        }
    }

    // MARK: text cleanup

    /// Remove ```fences```, `<tool_call>…</tool_call>` / `<function_call>…</…>`
    /// tags. Leaves whatever's between (or, if no wrapper, the whole string).
    private static func stripWrappers(_ s: String) -> String {
        var t = s
        for tag in ["tool_call", "function_call", "tool", "function"] {
            t = t.replacingOccurrences(of: "<\(tag)>", with: " ")
                .replacingOccurrences(of: "</\(tag)>", with: " ")
        }
        // Drop code-fence lines (``` or ```json) but keep their contents.
        t = t.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
        return t
    }

    /// The first balanced `{ … }` substring (brace-counting, string-aware so a
    /// `}` inside a JSON string doesn't close the object), decoded to `[String: Any]`.
    private static func firstJSONObject(in s: String) -> [String: Any]? {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var depth = 0
            var inString = false
            var escaped = false
            var j = i
            while j < chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                } else {
                    if c == "\"" { inString = true }
                    else if c == "{" { depth += 1 }
                    else if c == "}" {
                        depth -= 1
                        if depth == 0 {
                            let candidate = String(chars[i...j])
                            if let data = candidate.data(using: .utf8),
                                let obj = try? JSONSerialization.jsonObject(with: data),
                                let dict = obj as? [String: Any] {
                                return dict
                            }
                            break  // unbalanced/invalid — try the next `{`
                        }
                    }
                }
                j += 1
            }
            i += 1
        }
        return nil
    }

    // MARK: tolerant accessors

    private static func stringValue(_ dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let v = dict[k] as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            if let n = dict[k] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    private static func dictValue(_ dict: [String: Any], keys: [String]) -> [String: Any]? {
        for k in keys { if let v = dict[k] as? [String: Any] { return v } }
        return nil
    }

    /// A `Date` from an ISO-8601 string (with/without fractional seconds, with/
    /// without time), or `yyyy-MM-dd` / `yyyy-MM` / `yyyy` (interpreted at UTC
    /// midnight, start of the period).
    private static func dateValue(_ dict: [String: Any], keys: [String]) -> Date? {
        guard let s = stringValue(dict, keys: keys) else { return nil }
        return parseDate(s)
    }

    /// A `DateInterval` from: a `{start,end}` (or `{from,to}`) object, a 2-element
    /// array `[a, b]`, or a single string that names a day / month / year.
    private static func rangeValue(_ dict: [String: Any], keys: [String]) -> DateInterval? {
        for k in keys {
            let v = dict[k]
            if let sub = v as? [String: Any] {
                let startS = stringValue(sub, keys: ["start", "from", "begin"])
                let endS = stringValue(sub, keys: ["end", "to", "until", "finish"])
                if let a = startS.flatMap(parseDate), let b = endS.flatMap(parseDate), b >= a {
                    return DateInterval(start: a, end: b)
                }
            }
            if let arr = v as? [Any], arr.count == 2,
                let a = (arr[0] as? String).flatMap(parseDate),
                let b = (arr[1] as? String).flatMap(parseDate), b >= a {
                return DateInterval(start: a, end: b)
            }
            if let s = v as? String, let interval = parsePeriod(s) { return interval }
        }
        return nil
    }

    // MARK: date helpers (UTC, deterministic)

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }()

    private static func parseDate(_ s: String) -> Date? {
        let str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Full ISO-8601 timestamps.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) { return d }
        // Date-only / month-only / year-only → start of that period (UTC).
        return parsePeriod(str)?.start
    }

    /// A calendar period named by `yyyy`, `yyyy-MM`, or `yyyy-MM-dd` → its
    /// `[start, end)` interval (UTC). Returns nil for anything else.
    private static func parsePeriod(_ s: String) -> DateInterval? {
        let parts = s.split(separator: "-").map(String.init)
        guard let year = Int(parts.first ?? ""), (1...9999).contains(year) else { return nil }
        var comps = DateComponents()
        comps.year = year
        let component: Calendar.Component
        switch parts.count {
        case 1: component = .year
        case 2:
            guard let m = Int(parts[1]), (1...12).contains(m) else { return nil }
            comps.month = m; component = .month
        case 3:
            guard let m = Int(parts[1]), (1...12).contains(m),
                let d = Int(parts[2]), (1...31).contains(d) else { return nil }
            comps.month = m; comps.day = d; component = .day
        default: return nil
        }
        guard let start = utcCalendar.date(from: comps),
            let interval = utcCalendar.dateInterval(of: component, for: start) else { return nil }
        return interval
    }
}
