import Testing
import Foundation
@testable import MnemoEngine

@Suite("RecallPromptBuilder — assembles the strings the on-device model completes")
struct RecallPromptBuilderTests {

    private func event(_ text: String, _ ago: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: Date().addingTimeInterval(-ago), source: .screen, text: text)
    }

    @Test("recallPrompt: includes the question, numbered events, the answer-JSON instruction and the flag escape")
    func recallPromptShape() {
        let b = RecallPromptBuilder()
        let p = b.recallPrompt(
            query: "when is the dentist",
            contextEvents: [event("dentist Thursday 3pm", 3600), event("lease due the 14th", 7200)],
            contextSummaries: [DailySummary(date: DateInterval(start: Date().addingTimeInterval(-86400), duration: 86400), summary: "moving week")],
            locale: Locale(identifier: "en_US")
        )
        #expect(p.contains("when is the dentist"))
        #expect(p.contains("[1] "))
        #expect(p.contains("[2] "))
        #expect(p.contains("(S1) "))
        #expect(p.contains("\"answer\""))
        #expect(p.contains("flag_for_human"))
        #expect(p.contains("set_reminder"))
        #expect(p.contains(RecallPromptBuilder.defaultPreamble))
    }

    @Test("recallPrompt with no context says so")
    func recallPromptEmpty() {
        let p = RecallPromptBuilder().recallPrompt(query: "anything", contextEvents: [], contextSummaries: [])
        #expect(p.contains("No recorded events"))
        #expect(p.contains("anything"))
    }

    @Test("simplifyPrompt carries the text and the reading level")
    func simplifyPromptShape() {
        let p = RecallPromptBuilder().simplifyPrompt("A complex sentence (with an aside).", toReadingLevel: 5)
        #expect(p.contains("grade-5"))
        #expect(p.contains("A complex sentence"))
    }

    @Test("summarizeDayPrompt / summarizeRollupPrompt carry the inputs")
    func summaryPrompts() {
        let b = RecallPromptBuilder()
        let day = DateInterval(start: Date().addingTimeInterval(-86400), duration: 86400)
        let dp = b.summarizeDayPrompt(events: [event("kickoff meeting", 3600)], dayBucket: day)
        #expect(dp.contains("kickoff meeting"))
        #expect(dp.lowercased().contains("summar"))
        let rp = b.summarizeRollupPrompt(tier: .weekly, span: day, childSummaries: ["mon: x", "tue: y"])
        #expect(rp.contains("mon: x"))
        #expect(rp.contains("weekly"))
    }
}
