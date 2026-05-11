// The frozen contract for the recall turn's native-function-calling dispatch.
// Lock the shape early (the He Was Socrates lesson): everything downstream —
// the parser, the orchestrator, the .real GemmaService prompt — depends on it.
// Phase 1 represents it as data + a JSON-schema-ish description; Phase 3 feeds
// the description into the model's tool spec.

import Foundation

public struct RecallFunctionContract: Sendable {
    public struct FunctionSpec: Sendable, Equatable {
        public let name: String
        public let purpose: String
        public let parameters: [Parameter]
        public struct Parameter: Sendable, Equatable {
            public let name: String
            public let type: String          // "string" | "string?" | "iso8601-range?" | "int?" | "modality?"
            public let note: String
        }
    }

    public static let functions: [FunctionSpec] = [
        FunctionSpec(
            name: "recall_events",
            purpose: "Return the recorded events that answer the user's question, with citations.",
            parameters: [
                .init(name: "query", type: "string", note: "the user's question, normalized"),
                .init(name: "time_range", type: "iso8601-range?", note: "optional explicit scope"),
            ]
        ),
        FunctionSpec(
            name: "summarize_period",
            purpose: "Synthesize a summary of a span of the user's recorded life.",
            parameters: [
                .init(name: "time_range", type: "iso8601-range", note: "the span to summarize"),
            ]
        ),
        FunctionSpec(
            name: "find_entity_mentions",
            purpose: "Return every recorded event that mentions a given person, place, or thing.",
            parameters: [
                .init(name: "entity", type: "string", note: "surface form of the entity"),
            ]
        ),
        FunctionSpec(
            name: "set_reminder",
            purpose: "Schedule a future surfacing.",
            parameters: [
                .init(name: "when", type: "iso8601", note: "when to surface it"),
                .init(name: "what", type: "string", note: "the reminder text"),
                .init(name: "surface_modality", type: "modality?", note: "optional preferred output channel"),
            ]
        ),
        FunctionSpec(
            name: "flag_for_human",
            purpose: "Decline to answer; route the user to a human (medical/legal/financial/immigration/emergency).",
            parameters: [
                .init(name: "reason", type: "string", note: "why this is out of scope"),
                .init(name: "resource_class", type: "string", note: "e.g. 'a doctor', 'a lawyer'"),
            ]
        ),
    ]

    /// A compact textual description suitable for a model tool-spec prompt.
    public static var toolSpecDescription: String {
        functions.map { f in
            let params = f.parameters.map { "    \($0.name): \($0.type)  — \($0.note)" }.joined(separator: "\n")
            return "- \(f.name)(...)  — \(f.purpose)\n\(params)"
        }.joined(separator: "\n")
    }
}
