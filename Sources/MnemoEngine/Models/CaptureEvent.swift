// What was recorded. Capture must be cheap and durable: an event lands with
// the SHA-256 fingerprint computed synchronously and everything else `nil`;
// a background `EventEnricher` fills `embedding`/`entities`/`structure` later.
// Embedding inference is NEVER in the capture write path. (Critic-loop §10.)

import Foundation
import CryptoKit

public enum CaptureSource: String, Codable, Sendable, CaseIterable {
    case screen
    case audio
    case clipboard
    case file
    case manual
}

/// Coarse structural tags the enricher attaches (positional, not semantic).
public enum StructureTag: Codable, Sendable, Equatable {
    case document
    case heading(level: Int)
    case chatMessage(sender: String)   // sender is positional ("A"/"B") unless the user names it
    case uiElement
    case codeBlock
    case table
    case caption
}

/// A person/place/thing the enricher noticed. `resolvedName` is non-nil only
/// if the user explicitly named this entity — otherwise it's positional.
public struct EntityMention: Codable, Sendable, Equatable {
    public var surfaceForm: String      // the text as it appeared
    public var kind: Kind
    public var resolvedName: String?    // user-assigned identity, if any

    public enum Kind: String, Codable, Sendable { case person, place, organization, thing, date }

    public init(surfaceForm: String, kind: Kind, resolvedName: String? = nil) {
        self.surfaceForm = surfaceForm; self.kind = kind; self.resolvedName = resolvedName
    }
}

public enum SensitivityTag: String, Codable, Sendable {
    case normal
    case sensitive          // financial/health/legal keywords detected — won't surface unprompted
    case userMarkedPrivate  // never surfaces unprompted, never echoed
}

/// Reference to a stored raw blob (screenshot / audio clip), encrypted.
/// Absent when `rawRetention == .textOnly` (the default) or after pruning.
public struct BlobRef: Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: Kind
    public var byteCount: Int
    public enum Kind: String, Codable, Sendable { case image, audio }
    public init(id: UUID = UUID(), kind: Kind, byteCount: Int) {
        self.id = id; self.kind = kind; self.byteCount = byteCount
    }
}

/// Which app/window an on-screen or clipboard capture came from — used for
/// blackout rules (never capture in a password manager, a banking app, …).
public struct AppContext: Codable, Sendable, Equatable {
    public var bundleId: String
    public var windowTitle: String?
    public init(bundleId: String, windowTitle: String? = nil) {
        self.bundleId = bundleId; self.windowTitle = windowTitle
    }
}

public struct CaptureEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let source: CaptureSource
    public var text: String                  // the extracted/transcribed text
    public var rawRef: BlobRef?              // nil in text-only mode / after pruning
    public var appContext: AppContext?
    public var sensitivity: SensitivityTag

    // --- deferred enrichment (nil at capture time; the EventEnricher fills these) ---
    public var embedding: [Float]?
    public var entities: [EntityMention]?
    public var structure: [StructureTag]?

    /// SHA-256 over (text + day-bucket + sourceWindowId) — content-fingerprint
    /// dedup, computed synchronously at capture (cheap; no inference).
    public let fingerprint: Data

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        source: CaptureSource,
        text: String,
        rawRef: BlobRef? = nil,
        appContext: AppContext? = nil,
        sensitivity: SensitivityTag = .normal,
        embedding: [Float]? = nil,
        entities: [EntityMention]? = nil,
        structure: [StructureTag]? = nil,
        calendar: Calendar = .init(identifier: .iso8601)
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.text = text
        self.rawRef = rawRef
        self.appContext = appContext
        self.sensitivity = sensitivity
        self.embedding = embedding
        self.entities = entities
        self.structure = structure
        self.fingerprint = Self.fingerprint(
            text: text, timestamp: timestamp, source: source,
            windowKey: appContext?.windowTitle ?? appContext?.bundleId,
            calendar: calendar
        )
    }

    /// The dedup key: same text, same day-bucket, same source-window → same fingerprint.
    public static func fingerprint(
        text: String, timestamp: Date, source: CaptureSource,
        windowKey: String?, calendar: Calendar = .init(identifier: .iso8601)
    ) -> Data {
        var c = calendar
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let day = c.dateComponents([.year, .month, .day], from: timestamp)
        let dayKey = "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        let material = "\(text)\u{1F}\(dayKey)\u{1F}\(source.rawValue)\u{1F}\(windowKey ?? "-")"
        return Data(SHA256.hash(data: Data(material.utf8)))
    }

    /// True once the background enricher has run.
    public var isEnriched: Bool { embedding != nil }
}
