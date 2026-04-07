import AVFoundation
import Foundation

/// Wraps AVPlayer with KVO observers, time observer, and seek fencing.
///
/// Uses actor isolation to serialize all access to AVPlayer and the state
/// machine. With iOS 16+ as the minimum deployment target, AVPlayer's
/// mutable properties (`rate`, `volume`, `pause()`, `seek()`) are
/// `nonisolated` in the SDK and safe to access from any serial context.
/// Emits state changes and time updates via `AsyncStream`.
public actor AVPlayerAdapter {

   private var player: AVPlayer?
   private var playerItem: AVPlayerItem?
   private var timeObserverToken: Any?

   public private(set) var stateMachine = PlaybackStateMachine()

   /// The desired playback rate, stored so we can re-apply it after pause/play.
   private var desiredRate: Float = 1.0

   /// The actual volume level (separate from mute state).
   private var actualVolume: Float = 1.0

   // MARK: - KVO observation tokens

   private var itemStatusObservation: NSKeyValueObservation?
   private var itemDurationObservation: NSKeyValueObservation?

   // MARK: - NotificationCenter observer tokens

   private var didPlayToEndObserver: NSObjectProtocol?
   private var failedToPlayToEndObserver: NSObjectProtocol?

   // MARK: - AsyncStream event channels

   public nonisolated let stateChanges: AsyncStream<PlayerStateSnapshot>
   public nonisolated let timeUpdates: AsyncStream<TimeUpdate>

   private let stateContinuation: AsyncStream<PlayerStateSnapshot>.Continuation
   private let timeContinuation: AsyncStream<TimeUpdate>.Continuation

   // MARK: - Lifecycle

   public init() {
      (stateChanges, stateContinuation) = AsyncStream.makeStream()
      (timeUpdates, timeContinuation) = AsyncStream.makeStream()
   }

   deinit {
      if let token = timeObserverToken {
         player?.removeTimeObserver(token)
      }
      if let observer = didPlayToEndObserver {
         NotificationCenter.default.removeObserver(observer)
      }
      if let observer = failedToPlayToEndObserver {
         NotificationCenter.default.removeObserver(observer)
      }
      itemStatusObservation?.invalidate()
      itemDurationObservation?.invalidate()

      stateContinuation.finish()
      timeContinuation.finish()
   }

   // MARK: - Transport actions

   public func load(src: String, metadata: AudioMetadata) throws -> AudioActionResponse {
      try stateMachine.beginLoad(src: src, metadata: metadata)
      emitStateChanged()

      teardownPlayer()

      let url: URL
      if src.hasPrefix("http://") || src.hasPrefix("https://") {
         guard let parsed = URL(string: src) else {
            stateMachine.error("Invalid URL: \(src)")
            emitStateChanged()
            throw AudioError.invalidValue("Invalid URL: \(src)")
         }
         url = parsed
      } else {
         url = URL(fileURLWithPath: src)
      }

      let item = AVPlayerItem(url: url)
      let avPlayer = AVPlayer(playerItem: item)
      avPlayer.automaticallyWaitsToMinimizeStalling = true

      self.player = avPlayer
      self.playerItem = item

      applyVolumeToPlayer()
      avPlayer.rate = 0 // Start paused

      setupObservers(for: avPlayer, item: item)

      // The actual Ready transition happens in the KVO callback when
      // AVPlayerItem.status becomes .readyToPlay. Return the current
      // (Loading) state for now.
      return AudioActionResponse(
         player: stateMachine.snapshot(),
         expectedStatus: .ready
      )
   }

   public func play() throws -> AudioActionResponse {
      let wasEnded = stateMachine.status == .ended

      try stateMachine.play()

      if wasEnded {
         player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
      }

      player?.rate = desiredRate
      emitStateChanged()
      startTimeObserver()

      return AudioActionResponse(
         player: stateMachine.snapshot(),
         expectedStatus: .playing
      )
   }

   public func pause() throws -> AudioActionResponse {
      try stateMachine.pause()

      player?.pause()
      stopTimeObserver()
      emitStateChanged()

      return AudioActionResponse(
         player: stateMachine.snapshot(),
         expectedStatus: .paused
      )
   }

   public func stop() throws -> AudioActionResponse {
      try stateMachine.stop()

      teardownPlayer()
      emitStateChanged()

      return AudioActionResponse(
         player: stateMachine.snapshot(),
         expectedStatus: .idle
      )
   }

   public func seek(position: Double) throws -> AudioActionResponse {
      try stateMachine.seek(position: position)

      let targetTime = CMTime(seconds: stateMachine.currentTime, preferredTimescale: 600)
      let capturedSourceRevision = stateMachine.sourceRevision
      let capturedSeekRevision = stateMachine.seekRevision

      player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
         Task {
            await self?.resolveSeek(
               sourceRevision: capturedSourceRevision,
               seekRevision: capturedSeekRevision
            )
         }
      }

      emitStateChanged()

      return AudioActionResponse(
         player: stateMachine.snapshot(),
         expectedStatus: stateMachine.status
      )
   }

   // MARK: - Settings

   public func setVolume(level: Double) throws -> PlayerStateSnapshot {
      try stateMachine.setVolume(level: level)
      actualVolume = Float(stateMachine.volume)
      applyVolumeToPlayer()
      emitStateChanged()
      return stateMachine.snapshot()
   }

   public func setMuted(_ muted: Bool) -> PlayerStateSnapshot {
      stateMachine.setMuted(muted)
      applyVolumeToPlayer()
      emitStateChanged()
      return stateMachine.snapshot()
   }

   public func setPlaybackRate(_ rate: Double) throws -> PlayerStateSnapshot {
      try stateMachine.setPlaybackRate(rate)
      desiredRate = Float(stateMachine.playbackRate)

      if stateMachine.status == .playing {
         player?.rate = desiredRate
      }

      emitStateChanged()
      return stateMachine.snapshot()
   }

   public func setLoop(_ looping: Bool) -> PlayerStateSnapshot {
      stateMachine.setLoop(looping)
      emitStateChanged()
      return stateMachine.snapshot()
   }

   public func state() -> PlayerStateSnapshot {
      return stateMachine.snapshot()
   }

   // MARK: - Private: Actor-isolated handlers for async callbacks

   private func resolveSeek(sourceRevision: Int64, seekRevision: Int64) {
      stateMachine.resolveSeek(sourceRevision: sourceRevision, seekRevision: seekRevision)
   }

   private func handleItemStatus(item: AVPlayerItem, sourceRevision: Int64) {
      guard sourceRevision == stateMachine.sourceRevision else { return }

      switch item.status {
      case .readyToPlay:
         let durationSeconds = CMTimeGetSeconds(item.duration)
         let dur = durationSeconds.isFinite ? durationSeconds : 0.0

         guard let src = stateMachine.src else { return }
         let metadata = AudioMetadata(
            title: stateMachine.title,
            artist: stateMachine.artist,
            artwork: stateMachine.artwork
         )

         do {
            try stateMachine.load(src: src, metadata: metadata, duration: dur)
            emitStateChanged()
         } catch {
            // State may have changed between beginLoad and readyToPlay callback
         }

      case .failed:
         let message = item.error?.localizedDescription ?? "Unknown playback error"
         stateMachine.error(message)
         emitStateChanged()

      case .unknown:
         break

      @unknown default:
         break
      }
   }

   private func handleDurationChange(item: AVPlayerItem, sourceRevision: Int64) {
      guard sourceRevision == stateMachine.sourceRevision else { return }

      let durationSeconds = CMTimeGetSeconds(item.duration)
      guard durationSeconds.isFinite, durationSeconds > 0 else { return }

      if stateMachine.duration == 0.0, stateMachine.status == .ready {
         guard let src = stateMachine.src else { return }
         let metadata = AudioMetadata(
            title: stateMachine.title,
            artist: stateMachine.artist,
            artwork: stateMachine.artwork
         )
         try? stateMachine.load(src: src, metadata: metadata, duration: durationSeconds)
         emitStateChanged()
      }
   }

   private func handleDidPlayToEnd() {
      if stateMachine.looping {
         player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task {
               await self?.resumeAfterLoop()
            }
         }
         timeContinuation.yield(TimeUpdate(currentTime: 0.0, duration: stateMachine.duration))
      } else {
         stateMachine.ended()
         stopTimeObserver()
         emitStateChanged()
      }
   }

   private func resumeAfterLoop() {
      player?.rate = desiredRate
   }

   private func handleFailedToPlayToEnd() {
      let message = playerItem?.error?.localizedDescription ?? "Playback failed"
      stateMachine.error(message)
      stopTimeObserver()
      emitStateChanged()
   }

   private func emitTimeUpdate(seconds: Double) {
      timeContinuation.yield(TimeUpdate(
         currentTime: seconds,
         duration: stateMachine.duration
      ))
   }

   // MARK: - Private: Observer setup

   private func setupObservers(for avPlayer: AVPlayer, item: AVPlayerItem) {
      let capturedRevision = stateMachine.sourceRevision

      itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
         Task { await self?.handleItemStatus(item: item, sourceRevision: capturedRevision) }
      }

      itemDurationObservation = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
         Task { await self?.handleDurationChange(item: item, sourceRevision: capturedRevision) }
      }

      didPlayToEndObserver = NotificationCenter.default.addObserver(
         forName: .AVPlayerItemDidPlayToEndTime,
         object: item,
         queue: nil
      ) { [weak self] _ in
         Task { await self?.handleDidPlayToEnd() }
      }

      failedToPlayToEndObserver = NotificationCenter.default.addObserver(
         forName: .AVPlayerItemFailedToPlayToEndTime,
         object: item,
         queue: nil
      ) { [weak self] _ in
         Task { await self?.handleFailedToPlayToEnd() }
      }
   }

   // MARK: - Private: Time observer

   private func startTimeObserver() {
      stopTimeObserver()

      guard let avPlayer = player else { return }

      // 4 Hz (250ms) matching the Rodio monitor interval
      let interval = CMTime(seconds: 0.25, preferredTimescale: 600)

      timeObserverToken = avPlayer.addPeriodicTimeObserver(
         forInterval: interval,
         queue: nil
      ) { [weak self] time in
         let seconds = CMTimeGetSeconds(time)
         guard seconds.isFinite else { return }
         Task { await self?.emitTimeUpdate(seconds: seconds) }
      }
   }

   private func stopTimeObserver() {
      if let token = timeObserverToken {
         player?.removeTimeObserver(token)
         timeObserverToken = nil
      }
   }

   // MARK: - Private: Helpers

   private func applyVolumeToPlayer() {
      if stateMachine.muted {
         player?.volume = 0.0
      } else {
         player?.volume = actualVolume
      }
   }

   private func teardownPlayer() {
      stopTimeObserver()

      if let observer = didPlayToEndObserver {
         NotificationCenter.default.removeObserver(observer)
         didPlayToEndObserver = nil
      }
      if let observer = failedToPlayToEndObserver {
         NotificationCenter.default.removeObserver(observer)
         failedToPlayToEndObserver = nil
      }

      itemStatusObservation?.invalidate()
      itemStatusObservation = nil
      itemDurationObservation?.invalidate()
      itemDurationObservation = nil

      player?.pause()
      player?.replaceCurrentItem(with: nil)
      player = nil
      playerItem = nil
   }

   private func emitStateChanged() {
      stateContinuation.yield(stateMachine.snapshot())
   }
}
