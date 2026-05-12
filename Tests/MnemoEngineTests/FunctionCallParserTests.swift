import Testing
import Foundation
@testable import MnemoEngine

@Suite("FunctionCallParser — tolerant decode of the recall model's function-call output")
struct FunctionCallParserTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .iso8601); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }()
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test("Clean JSON object → recall_events")
    func cleanRecallEvents() {
        let out = FunctionCallParser.parse(#"{"name": "recall_events", "arguments": {"query": "what did Jordan say"}}"#)
        #expect(out == .recallEvents(query: "what did Jordan say", timeRange: nil))
    }

    @Test("Markdown-fenced JSON is unwrapped")
    func fenced() {
        let text = """
        Sure — I'll look that up.
        ```json
        {"name": "find_entity_mentions", "arguments": {"entity": "the lease"}}
        ```
        """
        #expect(FunctionCallParser.parse(text) == .findEntityMentions(entity: "the lease"))
    }

    @Test("<tool_call> tags are unwrapped; prose around the JSON is ignored")
    func toolCallTags() {
        let text = #"I'll set that. <tool_call>{"name":"set_reminder","arguments":{"when":"2026-07-01T09:00:00Z","what":"renew the lease"}}</tool_call> Done."#
        let out = FunctionCallParser.parse(text)
        #expect(out == .setReminder(when: date(2026, 7, 1, 9, 0), what: "renew the lease", surfaceModality: nil))
    }

    @Test("set_reminder with a surface_modality")
    func setReminderWithModality() {
        let out = FunctionCallParser.parse(#"{"name":"set_reminder","arguments":{"when":"2026-07-01T09:00:00Z","what":"renew the lease","surface_modality":"haptic"}}"#)
        #expect(out == .setReminder(when: date(2026, 7, 1, 9, 0), what: "renew the lease", surfaceModality: .haptic))
    }

    @Test("summarize_period — time_range as a {start,end} object")
    func summarizePeriodObjectRange() {
        let out = FunctionCallParser.parse(#"{"name":"summarize_period","arguments":{"time_range":{"start":"2026-03-01T00:00:00Z","end":"2026-03-31T00:00:00Z"}}}"#)
        #expect(out == .summarizePeriod(timeRange: DateInterval(start: date(2026, 3, 1), end: date(2026, 3, 31))))
    }

    @Test("summarize_period — time_range as a 2-element array")
    func summarizePeriodArrayRange() {
        let out = FunctionCallParser.parse(#"{"name":"summarize_period","arguments":{"time_range":["2026-03-01","2026-03-08"]}}"#)
        #expect(out == .summarizePeriod(timeRange: DateInterval(start: date(2026, 3, 1), end: date(2026, 3, 8))))
    }

    @Test("recall_events — time_range named as a single month string expands to the whole month")
    func recallEventsMonthRange() {
        let out = FunctionCallParser.parse(#"{"name":"recall_events","arguments":{"query":"moving","time_range":"2026-03"}}"#)
        #expect(out == .recallEvents(query: "moving", timeRange: DateInterval(start: date(2026, 3, 1), end: date(2026, 4, 1))))
    }

    @Test("flag_for_human carries the reason + resource class")
    func flagForHuman() {
        let out = FunctionCallParser.parse(#"{"name":"flag_for_human","arguments":{"reason":"this asks for medical advice","resource_class":"a doctor"}}"#)
        #expect(out == .flagForHuman(reason: "this asks for medical advice", resourceClass: "a doctor"))
    }

    @Test("flag_for_human with only a reason → a sane default resource class")
    func flagForHumanDefaultResource() {
        let out = FunctionCallParser.parse(#"{"name":"flag_for_human","arguments":{"reason":"out of scope"}}"#)
        if case .flagForHuman(let reason, let resource) = out {
            #expect(reason == "out of scope")
            #expect(!resource.isEmpty)
        } else { Issue.record("expected flagForHuman") }
    }

    @Test("Alternate key names: `function` + `parameters` + `q`")
    func alternateKeys() {
        let out = FunctionCallParser.parse(#"{"function":"recall_events","parameters":{"q":"the dentist appointment"}}"#)
        #expect(out == .recallEvents(query: "the dentist appointment", timeRange: nil))
    }

    @Test("Args inlined at the top level (no nested bag) still parse")
    func inlinedArgs() {
        let out = FunctionCallParser.parse(#"{"name":"find_entity_mentions","entity":"Jordan"}"#)
        #expect(out == .findEntityMentions(entity: "Jordan"))
    }

    @Test("A `}` inside a JSON string doesn't prematurely close the object")
    func braceInsideString() {
        let out = FunctionCallParser.parse(#"{"name":"recall_events","arguments":{"query":"the note that said {done}"}}"#)
        #expect(out == .recallEvents(query: "the note that said {done}", timeRange: nil))
    }

    @Test("No JSON at all → unparseable, carrying the raw text")
    func noJSON() {
        let raw = "I don't think I have anything about that."
        #expect(FunctionCallParser.parse(raw) == .unparseable(rawText: raw))
    }

    @Test("Missing the required argument → unparseable (not a half-built call)")
    func missingRequiredArg() {
        #expect(FunctionCallParser.parse(#"{"name":"recall_events","arguments":{}}"#) == .unparseable(rawText: #"{"name":"recall_events","arguments":{}}"#))
        #expect(FunctionCallParser.parse(#"{"name":"summarize_period","arguments":{}}"#) == .unparseable(rawText: #"{"name":"summarize_period","arguments":{}}"#))
    }

    @Test("Unknown function name → unparseable")
    func unknownFunction() {
        let raw = #"{"name":"delete_everything","arguments":{}}"#
        #expect(FunctionCallParser.parse(raw) == .unparseable(rawText: raw))
    }

    @Test("UnavailableFunctionCallGenerator throws — the dependency-free engine ships no model runtime")
    func generatorUnavailable() async {
        let gen = UnavailableFunctionCallGenerator()
        await #expect(throws: FunctionCallGenerationError.self) {
            _ = try await gen.generate(prompt: "anything", maxTokens: 64)
        }
    }
}
