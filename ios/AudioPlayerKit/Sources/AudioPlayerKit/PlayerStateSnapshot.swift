import Foundation

/// Encodable snapshot matching the `PlayerState` JSON shape from `models.rs`.
///
/// All fields use camelCase to match the TypeScript layer expectations.
/// This is a value type that can safely cross isolation boundaries.
public struct PlayerStateSnapshot: Encodable, Sendable {
   public let status: PlaybackStatus
   public let src: String?
   public let title: String?
   public let artist: String?
   public let artwork: String?
   public let currentTime: Double
   public let duration: Double
   public let volume: Double
   public let muted: Bool
   public let playbackRate: Double
   public let loop: Bool
   public let error: String?
}

/// Response from a transport action (load, play, pause, stop, seek).
///
/// Wraps the resulting player state with status-expectation metadata so the
/// TypeScript layer can detect unexpected state transitions.
public struct AudioActionResponse: Encodable, Sendable {
   public let player: PlayerStateSnapshot
   public let expectedStatus: PlaybackStatus
   public let isExpectedStatus: Bool

   public init(player: PlayerStateSnapshot, expectedStatus: PlaybackStatus) {
      self.player = player
      self.expectedStatus = expectedStatus
      self.isExpectedStatus = player.status == expectedStatus
   }
}

/// Lightweight time update payload emitted at high frequency during playback.
///
/// Separated from `PlayerStateSnapshot` to avoid serializing the full state
/// on every tick (~250ms).
public struct TimeUpdate: Encodable, Sendable {
   public let currentTime: Double
   public let duration: Double

   public init(currentTime: Double, duration: Double) {
      self.currentTime = currentTime
      self.duration = duration
   }
}

/// Metadata for the audio source, used for OS transport control integration.
public struct AudioMetadata: Sendable {
   public let title: String?
   public let artist: String?
   public let artwork: String?

   public init(title: String? = nil, artist: String? = nil, artwork: String? = nil) {
      self.title = title
      self.artist = artist
      self.artwork = artwork
   }
}
