import XCTest
@testable import AudioPlayerKit

final class PlaybackStateMachineTests: XCTestCase {

   // MARK: - Helpers

   private func stateWithStatus(_ status: PlaybackStatus) -> PlaybackStateMachine {
      var sm = PlaybackStateMachine()
      // Use internal transitions to reach the desired status.
      switch status {
      case .idle:
         break
      case .loading:
         try! sm.beginLoad(src: "test.mp3", metadata: AudioMetadata())
      case .ready:
         try! sm.beginLoad(src: "test.mp3", metadata: AudioMetadata())
         try! sm.load(src: "test.mp3", metadata: AudioMetadata(), duration: 120.0)
      case .playing:
         try! sm.beginLoad(src: "test.mp3", metadata: AudioMetadata())
         try! sm.load(src: "test.mp3", metadata: AudioMetadata(), duration: 120.0)
         try! sm.play()
      case .paused:
         try! sm.beginLoad(src: "test.mp3", metadata: AudioMetadata())
         try! sm.load(src: "test.mp3", metadata: AudioMetadata(), duration: 120.0)
         try! sm.play()
         try! sm.pause()
      case .ended:
         try! sm.beginLoad(src: "test.mp3", metadata: AudioMetadata())
         try! sm.load(src: "test.mp3", metadata: AudioMetadata(), duration: 120.0)
         try! sm.play()
         sm.ended()
      case .error:
         try! sm.beginLoad(src: "test.mp3", metadata: AudioMetadata())
         sm.error("test error")
      }
      XCTAssertEqual(sm.status, status)
      return sm
   }

   private func stateWithDuration(_ status: PlaybackStatus, duration: Double) -> PlaybackStateMachine {
      var sm = PlaybackStateMachine()
      try! sm.beginLoad(src: "test.mp3", metadata: AudioMetadata())
      try! sm.load(src: "test.mp3", metadata: AudioMetadata(), duration: duration)
      switch status {
      case .ready:
         break
      case .playing:
         try! sm.play()
      case .paused:
         try! sm.play()
         try! sm.pause()
      case .ended:
         try! sm.play()
         sm.ended()
      default:
         XCTFail("stateWithDuration does not support \(status)")
      }
      XCTAssertEqual(sm.status, status)
      return sm
   }

   private func meta(_ title: String) -> AudioMetadata {
      AudioMetadata(title: title)
   }

   // MARK: - Initial state

   func testInitialState() {
      let sm = PlaybackStateMachine()
      XCTAssertEqual(sm.status, .idle)
      XCTAssertNil(sm.src)
      XCTAssertNil(sm.title)
      XCTAssertNil(sm.artist)
      XCTAssertNil(sm.artwork)
      XCTAssertEqual(sm.currentTime, 0.0)
      XCTAssertEqual(sm.duration, 0.0)
      XCTAssertEqual(sm.volume, 1.0)
      XCTAssertFalse(sm.muted)
      XCTAssertEqual(sm.playbackRate, 1.0)
      XCTAssertFalse(sm.looping)
      XCTAssertNil(sm.error)
   }

   // MARK: - beginLoad

   func testBeginLoadFromIdle() throws {
      var sm = stateWithStatus(.idle)
      try sm.beginLoad(src: "test.mp3", metadata: meta("Song"))

      XCTAssertEqual(sm.status, .loading)
      XCTAssertEqual(sm.src, "test.mp3")
      XCTAssertEqual(sm.title, "Song")
      XCTAssertEqual(sm.duration, 0.0)
      XCTAssertEqual(sm.currentTime, 0.0)
      XCTAssertNil(sm.error)
   }

   func testBeginLoadFromEnded() throws {
      var sm = stateWithStatus(.ended)
      try sm.beginLoad(src: "a.mp3", metadata: AudioMetadata())
      XCTAssertEqual(sm.status, .loading)
   }

   func testBeginLoadFromError() throws {
      var sm = stateWithStatus(.error)
      try sm.beginLoad(src: "a.mp3", metadata: AudioMetadata())
      XCTAssertEqual(sm.status, .loading)
   }

   func testBeginLoadRejectedFromLoading() {
      var sm = stateWithStatus(.loading)
      XCTAssertThrowsError(try sm.beginLoad(src: "a.mp3", metadata: AudioMetadata()))
      XCTAssertEqual(sm.status, .loading)
   }

   func testBeginLoadRejectedFromReady() {
      var sm = stateWithStatus(.ready)
      XCTAssertThrowsError(try sm.beginLoad(src: "a.mp3", metadata: AudioMetadata()))
   }

   func testBeginLoadRejectedFromPlaying() {
      var sm = stateWithStatus(.playing)
      XCTAssertThrowsError(try sm.beginLoad(src: "a.mp3", metadata: AudioMetadata()))
   }

   func testBeginLoadRejectedFromPaused() {
      var sm = stateWithStatus(.paused)
      XCTAssertThrowsError(try sm.beginLoad(src: "a.mp3", metadata: AudioMetadata()))
   }

   // MARK: - load (finalize)

   func testLoadFromLoading() throws {
      var sm = stateWithStatus(.loading)
      try sm.load(src: "test.mp3", metadata: meta("Song"), duration: 120.0)

      XCTAssertEqual(sm.status, .ready)
      XCTAssertEqual(sm.src, "test.mp3")
      XCTAssertEqual(sm.title, "Song")
      XCTAssertEqual(sm.duration, 120.0)
      XCTAssertEqual(sm.currentTime, 0.0)
      XCTAssertNil(sm.error)
   }

   func testLoadFromIdle() throws {
      var sm = stateWithStatus(.idle)
      try sm.load(src: "a.mp3", metadata: AudioMetadata(), duration: 0.0)
      XCTAssertEqual(sm.status, .ready)
   }

   func testLoadFromEnded() throws {
      var sm = stateWithStatus(.ended)
      try sm.load(src: "a.mp3", metadata: AudioMetadata(), duration: 0.0)
      XCTAssertEqual(sm.status, .ready)
   }

   func testLoadFromError() throws {
      var sm = stateWithStatus(.error)
      try sm.load(src: "a.mp3", metadata: AudioMetadata(), duration: 0.0)
      XCTAssertEqual(sm.status, .ready)
   }

   func testLoadRejectedFromReady() {
      var sm = stateWithStatus(.ready)
      XCTAssertThrowsError(try sm.load(src: "a.mp3", metadata: AudioMetadata(), duration: 0.0))
   }

   func testLoadRejectedFromPlaying() {
      var sm = stateWithStatus(.playing)
      XCTAssertThrowsError(try sm.load(src: "a.mp3", metadata: AudioMetadata(), duration: 0.0))
   }

   func testLoadRejectedFromPaused() {
      var sm = stateWithStatus(.paused)
      XCTAssertThrowsError(try sm.load(src: "a.mp3", metadata: AudioMetadata(), duration: 0.0))
   }

   // MARK: - play

   func testPlayFromReady() throws {
      var sm = stateWithStatus(.ready)
      try sm.play()
      XCTAssertEqual(sm.status, .playing)
   }

   func testPlayFromPaused() throws {
      var sm = stateWithStatus(.paused)
      try sm.play()
      XCTAssertEqual(sm.status, .playing)
   }

   func testPlayFromEnded() throws {
      var sm = stateWithStatus(.ended)
      try sm.play()
      XCTAssertEqual(sm.status, .playing)
   }

   func testPlayRejectedFromIdle() {
      var sm = stateWithStatus(.idle)
      XCTAssertThrowsError(try sm.play())
      XCTAssertEqual(sm.status, .idle)
   }

   func testPlayRejectedFromLoading() {
      var sm = stateWithStatus(.loading)
      XCTAssertThrowsError(try sm.play())
   }

   func testPlayRejectedFromPlaying() {
      var sm = stateWithStatus(.playing)
      XCTAssertThrowsError(try sm.play())
   }

   func testPlayRejectedFromError() {
      var sm = stateWithStatus(.error)
      XCTAssertThrowsError(try sm.play())
   }

   // MARK: - pause

   func testPauseFromPlaying() throws {
      var sm = stateWithStatus(.playing)
      try sm.pause()
      XCTAssertEqual(sm.status, .paused)
   }

   func testPauseRejectedFromIdle() {
      var sm = stateWithStatus(.idle)
      XCTAssertThrowsError(try sm.pause())
   }

   func testPauseRejectedFromReady() {
      var sm = stateWithStatus(.ready)
      XCTAssertThrowsError(try sm.pause())
   }

   func testPauseRejectedFromPaused() {
      var sm = stateWithStatus(.paused)
      XCTAssertThrowsError(try sm.pause())
   }

   func testPauseRejectedFromEnded() {
      var sm = stateWithStatus(.ended)
      XCTAssertThrowsError(try sm.pause())
   }

   func testPauseRejectedFromLoading() {
      var sm = stateWithStatus(.loading)
      XCTAssertThrowsError(try sm.pause())
   }

   func testPauseRejectedFromError() {
      var sm = stateWithStatus(.error)
      XCTAssertThrowsError(try sm.pause())
   }

   // MARK: - stop

   func testStopFromLoading() throws {
      var sm = stateWithStatus(.loading)
      try sm.stop()
      XCTAssertEqual(sm.status, .idle)
   }

   func testStopFromReady() throws {
      var sm = stateWithStatus(.ready)
      try sm.stop()
      XCTAssertEqual(sm.status, .idle)
   }

   func testStopFromPlaying() throws {
      var sm = stateWithStatus(.playing)
      try sm.stop()
      XCTAssertEqual(sm.status, .idle)
   }

   func testStopFromPaused() throws {
      var sm = stateWithStatus(.paused)
      try sm.stop()
      XCTAssertEqual(sm.status, .idle)
   }

   func testStopFromEnded() throws {
      var sm = stateWithStatus(.ended)
      try sm.stop()
      XCTAssertEqual(sm.status, .idle)
   }

   func testStopRejectedFromIdle() {
      var sm = stateWithStatus(.idle)
      XCTAssertThrowsError(try sm.stop())
   }

   func testStopRejectedFromError() {
      var sm = stateWithStatus(.error)
      XCTAssertThrowsError(try sm.stop())
   }

   func testStopPreservesSettings() throws {
      var sm = stateWithStatus(.playing)
      try sm.setVolume(level: 0.5)
      sm.setMuted(true)
      try sm.setPlaybackRate(1.5)
      sm.setLoop(true)

      try sm.stop()

      XCTAssertEqual(sm.status, .idle)
      XCTAssertEqual(sm.volume, 0.5)
      XCTAssertTrue(sm.muted)
      XCTAssertEqual(sm.playbackRate, 1.5)
      XCTAssertTrue(sm.looping)
      XCTAssertNil(sm.src)
      XCTAssertNil(sm.title)
      XCTAssertEqual(sm.currentTime, 0.0)
   }

   func testStopResetsSourceRevision() throws {
      var sm = stateWithStatus(.playing)
      try sm.stop()
      // After stop, sourceRevision is 1 (not 0) to prevent stale seek
      // callbacks from a previous track matching revision 0 on reload.
      XCTAssertEqual(sm.sourceRevision, 1)
   }

   // MARK: - seek

   func testSeekFromReady() throws {
      var sm = stateWithDuration(.ready, duration: 120.0)
      try sm.seek(position: 30.0)
      XCTAssertEqual(sm.currentTime, 30.0)
      XCTAssertEqual(sm.status, .ready)
   }

   func testSeekFromPlaying() throws {
      var sm = stateWithDuration(.playing, duration: 120.0)
      try sm.seek(position: 30.0)
      XCTAssertEqual(sm.currentTime, 30.0)
      XCTAssertEqual(sm.status, .playing)
   }

   func testSeekFromPaused() throws {
      var sm = stateWithDuration(.paused, duration: 120.0)
      try sm.seek(position: 15.0)
      XCTAssertEqual(sm.currentTime, 15.0)
      XCTAssertEqual(sm.status, .paused)
   }

   func testSeekFromEnded() throws {
      var sm = stateWithDuration(.ended, duration: 120.0)
      try sm.seek(position: 10.0)
      XCTAssertEqual(sm.currentTime, 10.0)
      XCTAssertEqual(sm.status, .ended)
   }

   func testSeekClampsNegativeToZero() throws {
      var sm = stateWithDuration(.ready, duration: 120.0)
      try sm.seek(position: -5.0)
      XCTAssertEqual(sm.currentTime, 0.0)
   }

   func testSeekClampsBeyondDuration() throws {
      var sm = stateWithDuration(.playing, duration: 120.0)
      try sm.seek(position: 999.0)
      XCTAssertEqual(sm.currentTime, 120.0)
   }

   func testSeekRejectedFromIdle() {
      var sm = stateWithStatus(.idle)
      XCTAssertThrowsError(try sm.seek(position: 10.0))
   }

   func testSeekRejectedFromLoading() {
      var sm = stateWithStatus(.loading)
      XCTAssertThrowsError(try sm.seek(position: 10.0))
   }

   func testSeekRejectedFromError() {
      var sm = stateWithStatus(.error)
      XCTAssertThrowsError(try sm.seek(position: 10.0))
   }

   func testSeekRejectsNaN() {
      var sm = stateWithStatus(.ready)
      XCTAssertThrowsError(try sm.seek(position: Double.nan))
      XCTAssertThrowsError(try sm.seek(position: Double.infinity))
   }

   // MARK: - setVolume

   func testSetVolumeClampsToRange() throws {
      var sm = PlaybackStateMachine()

      try sm.setVolume(level: 1.5)
      XCTAssertEqual(sm.volume, 1.0)

      try sm.setVolume(level: -0.5)
      XCTAssertEqual(sm.volume, 0.0)

      try sm.setVolume(level: 0.7)
      XCTAssertEqual(sm.volume, 0.7)
   }

   func testSetVolumeRejectsNaN() {
      var sm = PlaybackStateMachine()
      XCTAssertThrowsError(try sm.setVolume(level: Double.nan))
      XCTAssertThrowsError(try sm.setVolume(level: Double.infinity))
   }

   // MARK: - setMuted

   func testSetMutedUpdatesState() {
      var sm = PlaybackStateMachine()
      sm.setMuted(true)
      XCTAssertTrue(sm.muted)
      sm.setMuted(false)
      XCTAssertFalse(sm.muted)
   }

   // MARK: - setPlaybackRate

   func testSetPlaybackRateClampsToRange() throws {
      var sm = PlaybackStateMachine()

      try sm.setPlaybackRate(2.0)
      XCTAssertEqual(sm.playbackRate, 2.0)

      try sm.setPlaybackRate(0.0)
      XCTAssertEqual(sm.playbackRate, 0.25)

      try sm.setPlaybackRate(10.0)
      XCTAssertEqual(sm.playbackRate, 4.0)
   }

   func testSetPlaybackRateRejectsNaN() {
      var sm = PlaybackStateMachine()
      XCTAssertThrowsError(try sm.setPlaybackRate(Double.nan))
      XCTAssertThrowsError(try sm.setPlaybackRate(Double.infinity))
   }

   // MARK: - setLoop

   func testSetLoopUpdatesState() {
      var sm = PlaybackStateMachine()
      sm.setLoop(true)
      XCTAssertTrue(sm.looping)
      sm.setLoop(false)
      XCTAssertFalse(sm.looping)
   }

   // MARK: - error

   func testErrorFromLoading() {
      var sm = stateWithStatus(.loading)
      sm.error("decode failed")
      XCTAssertEqual(sm.status, .error)
      XCTAssertEqual(sm.error, "decode failed")
   }

   func testErrorFromPlaying() {
      var sm = stateWithStatus(.playing)
      sm.error("stream failed")
      XCTAssertEqual(sm.status, .error)
      XCTAssertEqual(sm.error, "stream failed")
   }

   func testErrorFromPaused() {
      var sm = stateWithStatus(.paused)
      sm.error("stream failed")
      XCTAssertEqual(sm.status, .error)
      XCTAssertEqual(sm.error, "stream failed")
   }

   func testErrorIgnoredFromIdle() {
      var sm = stateWithStatus(.idle)
      sm.error("should not apply")
      XCTAssertEqual(sm.status, .idle)
      XCTAssertNil(sm.error)
   }

   func testErrorIgnoredFromReady() {
      var sm = stateWithStatus(.ready)
      sm.error("should not apply")
      XCTAssertEqual(sm.status, .ready)
      XCTAssertNil(sm.error)
   }

   func testErrorIgnoredFromEnded() {
      var sm = stateWithStatus(.ended)
      sm.error("should not apply")
      XCTAssertEqual(sm.status, .ended)
      XCTAssertNil(sm.error)
   }

   // MARK: - ended

   func testEndedFromPlaying() {
      var sm = stateWithDuration(.playing, duration: 120.0)
      sm.ended()
      XCTAssertEqual(sm.status, .ended)
      XCTAssertEqual(sm.currentTime, 120.0)
   }

   func testEndedIgnoredFromPaused() {
      var sm = stateWithStatus(.paused)
      sm.ended()
      XCTAssertEqual(sm.status, .paused)
   }

   func testEndedIgnoredFromIdle() {
      var sm = stateWithStatus(.idle)
      sm.ended()
      XCTAssertEqual(sm.status, .idle)
   }

   // MARK: - resolveSeek

   func testResolveSeekMatchingRevisions() throws {
      var sm = stateWithDuration(.ready, duration: 120.0)
      try sm.seek(position: 30.0)
      XCTAssertNotNil(sm.pendingSeek)

      let sourceRev = sm.sourceRevision
      let seekRev = sm.seekRevision
      sm.resolveSeek(sourceRevision: sourceRev, seekRevision: seekRev)
      XCTAssertNil(sm.pendingSeek)
   }

   func testResolveSeekStaleRevisionIgnored() throws {
      var sm = stateWithDuration(.ready, duration: 120.0)
      try sm.seek(position: 30.0)
      XCTAssertNotNil(sm.pendingSeek)

      // Wrong seek revision — should not resolve
      sm.resolveSeek(sourceRevision: sm.sourceRevision, seekRevision: 999)
      XCTAssertNotNil(sm.pendingSeek)

      // Wrong source revision — should not resolve
      sm.resolveSeek(sourceRevision: 999, seekRevision: sm.seekRevision)
      XCTAssertNotNil(sm.pendingSeek)
   }

   // MARK: - Rollback on error

   func testFailedTransitionLeavesStateUnchanged() {
      var sm = stateWithStatus(.idle)
      let beforeStatus = sm.status
      _ = try? sm.play()
      XCTAssertEqual(sm.status, beforeStatus)

      var sm2 = stateWithStatus(.playing)
      _ = try? sm2.load(src: "a.mp3", metadata: AudioMetadata(), duration: 0.0)
      XCTAssertEqual(sm2.status, .playing)
   }

   // MARK: - Snapshot

   func testSnapshotMatchesState() throws {
      var sm = PlaybackStateMachine()
      try sm.beginLoad(src: "test.mp3", metadata: AudioMetadata(title: "Song", artist: "Artist"))
      try sm.load(src: "test.mp3", metadata: AudioMetadata(title: "Song", artist: "Artist"), duration: 180.0)
      try sm.setVolume(level: 0.8)
      sm.setMuted(true)

      let snapshot = sm.snapshot()
      XCTAssertEqual(snapshot.status, .ready)
      XCTAssertEqual(snapshot.src, "test.mp3")
      XCTAssertEqual(snapshot.title, "Song")
      XCTAssertEqual(snapshot.artist, "Artist")
      XCTAssertEqual(snapshot.duration, 180.0)
      XCTAssertEqual(snapshot.volume, 0.8)
      XCTAssertTrue(snapshot.muted)
      XCTAssertEqual(snapshot.playbackRate, 1.0)
      XCTAssertFalse(snapshot.loop)
   }
}
