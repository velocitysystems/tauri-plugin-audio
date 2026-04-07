import Foundation

/// Playback status matching the Rust `PlaybackStatus` enum in `models.rs`.
/// Raw values are the JSON strings expected by the TypeScript layer.
public enum PlaybackStatus: String, Encodable, Sendable {
   case idle
   case loading
   case ready
   case playing
   case paused
   case ended
   case error
}

/// Errors thrown when a state transition is invalid.
public enum AudioError: Error, LocalizedError, Sendable {

   case invalidState(String)
   case invalidValue(String)

   public var errorDescription: String? {
      switch self {
      case .invalidState(let msg):
         return "Invalid State: \(msg)"
      case .invalidValue(let msg):
         return "Invalid Value: \(msg)"
      }
   }
}

/// Tracks a pending async seek so stale completions can be discarded.
struct PendingSeek {
   let sourceRevision: Int64
   let seekRevision: Int64
   let position: Double
}

/// State machine for audio playback, faithfully porting `transitions.rs`.
///
/// This is the single source of truth for which state transitions are valid
/// and how player state fields are mutated on iOS. Every transition method
/// mirrors its Rust counterpart exactly.
public struct PlaybackStateMachine {

   // MARK: - State fields (match PlayerState in models.rs)

   public private(set) var status: PlaybackStatus = .idle
   public private(set) var src: String?
   public private(set) var title: String?
   public private(set) var artist: String?
   public private(set) var artwork: String?
   public private(set) var currentTime: Double = 0.0
   public private(set) var duration: Double = 0.0
   public private(set) var volume: Double = 1.0
   public private(set) var muted: Bool = false
   public private(set) var playbackRate: Double = 1.0
   public private(set) var looping: Bool = false
   public private(set) var error: String?

   // MARK: - Revision tracking for async seek fencing

   /// Incremented on each `beginLoad` to invalidate stale AVPlayer callbacks.
   private(set) var sourceRevision: Int64 = 0

   /// Incremented on each `seek` to invalidate stale seek completions.
   private(set) var seekRevision: Int64 = 0

   /// The currently pending seek, if any.
   private(set) var pendingSeek: PendingSeek?

   public init() {}

   /// Private initializer used by `stop()` to reset transport state while
   /// preserving user settings. The compiler enforces that all preserved
   /// fields are passed explicitly.
   private init(volume: Double, muted: Bool, playbackRate: Double, looping: Bool) {
      self.volume = volume
      self.muted = muted
      self.playbackRate = playbackRate
      self.looping = looping
      // sourceRevision starts at 1 so stale seek callbacks from a previous
      // track (which captured revision 0) cannot match after stop + reload.
      self.sourceRevision = 1
   }

   // MARK: - Transport actions

   /// Transitions to `loading` and stores metadata.
   ///
   /// Call before starting I/O so the frontend can show a loading indicator.
   /// After I/O completes, call `load(duration:)` to finalize to `ready`.
   public mutating func beginLoad(src: String, metadata: AudioMetadata) throws {
      switch status {
      case .idle, .ended, .error:
         break
      default:
         throw AudioError.invalidState("Cannot load in \(status.rawValue) state")
      }

      sourceRevision += 1
      self.status = .loading
      self.src = src
      self.title = metadata.title
      self.artist = metadata.artist
      self.artwork = metadata.artwork
      self.currentTime = 0.0
      self.duration = 0.0
      self.error = nil
      self.pendingSeek = nil
   }

   /// Finalizes a load by transitioning from `loading` to `ready` with the
   /// decoded duration. Also accepts `idle`, `ended`, and `error` in case
   /// `beginLoad` was skipped.
   public mutating func load(src: String, metadata: AudioMetadata, duration: Double) throws {
      switch status {
      case .loading, .idle, .ended, .error:
         break
      default:
         throw AudioError.invalidState("Cannot load in \(status.rawValue) state")
      }

      self.status = .ready
      self.src = src
      self.title = metadata.title
      self.artist = metadata.artist
      self.artwork = metadata.artwork
      self.currentTime = 0.0
      self.duration = duration
      self.error = nil
   }

   /// Validates and applies the play transition.
   public mutating func play() throws {
      switch status {
      case .ready, .paused, .ended:
         break
      default:
         throw AudioError.invalidState("Cannot play in \(status.rawValue) state")
      }
      status = .playing
   }

   /// Validates and applies the pause transition.
   public mutating func pause() throws {
      switch status {
      case .playing:
         break
      default:
         throw AudioError.invalidState("Cannot pause in \(status.rawValue) state")
      }
      status = .paused
   }

   /// Validates and applies the stop transition, preserving user settings.
   public mutating func stop() throws {
      switch status {
      case .loading, .ready, .playing, .paused, .ended:
         break
      default:
         throw AudioError.invalidState("Cannot stop in \(status.rawValue) state")
      }

      self = PlaybackStateMachine(
         volume: volume,
         muted: muted,
         playbackRate: playbackRate,
         looping: looping
      )
   }

   /// Validates and applies the seek transition. Preserves the current status.
   public mutating func seek(position: Double) throws {
      guard position.isFinite else {
         throw AudioError.invalidValue("Seek position must be finite, got \(position)")
      }

      switch status {
      case .ready, .playing, .paused, .ended:
         break
      default:
         throw AudioError.invalidState("Cannot seek in \(status.rawValue) state")
      }

      seekRevision += 1
      let clamped = min(max(position, 0.0), duration)
      currentTime = clamped
      pendingSeek = PendingSeek(
         sourceRevision: sourceRevision,
         seekRevision: seekRevision,
         position: clamped
      )
   }

   /// Resolves a pending seek if the revisions match (not stale).
   public mutating func resolveSeek(sourceRevision: Int64, seekRevision: Int64) {
      guard let pending = pendingSeek,
            pending.sourceRevision == sourceRevision,
            pending.seekRevision == seekRevision else {
         return
      }
      pendingSeek = nil
   }

   /// Transitions to `error` with a message.
   ///
   /// Valid from `loading` (I/O or decode failure during load), `playing`,
   /// or `paused` (e.g. network stream failure mid-playback). Other statuses
   /// are left unchanged.
   public mutating func error(_ message: String) {
      switch status {
      case .loading, .playing, .paused:
         status = .error
         self.error = message
      default:
         break
      }
   }

   /// Transitions to `ended`. Called by AVPlayer callbacks, not by user action.
   public mutating func ended() {
      if status == .playing {
         status = .ended
         currentTime = duration
      }
   }

   // MARK: - Settings

   /// Validates and applies a volume change.
   public mutating func setVolume(level: Double) throws {
      guard level.isFinite else {
         throw AudioError.invalidValue("Volume must be finite, got \(level)")
      }
      volume = min(max(level, 0.0), 1.0)
   }

   /// Applies a mute toggle.
   public mutating func setMuted(_ muted: Bool) {
      self.muted = muted
   }

   /// Validates and applies a playback rate change.
   public mutating func setPlaybackRate(_ rate: Double) throws {
      guard rate.isFinite else {
         throw AudioError.invalidValue("Playback rate must be finite, got \(rate)")
      }
      playbackRate = min(max(rate, 0.25), 4.0)
   }

   /// Applies a loop toggle.
   public mutating func setLoop(_ looping: Bool) {
      self.looping = looping
   }

   // MARK: - Snapshot

   /// Creates a `PlayerStateSnapshot` from the current state.
   public func snapshot() -> PlayerStateSnapshot {
      PlayerStateSnapshot(
         status: status,
         src: src,
         title: title,
         artist: artist,
         artwork: artwork,
         currentTime: currentTime,
         duration: duration,
         volume: volume,
         muted: muted,
         playbackRate: playbackRate,
         loop: looping,
         error: error
      )
   }
}
