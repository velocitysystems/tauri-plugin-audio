import Foundation
import MediaPlayer

/// Events dispatched from remote command handlers back to the audio coordinator.
public enum RemoteCommandEvent: Sendable {
   case play
   case pause
   case togglePlayPause
   case changePlaybackPosition(Double)
   case skipForward(Double)
   case skipBackward(Double)
}

/// Manages MPRemoteCommandCenter registration for lock screen, headphone,
/// and Control Center controls.
public actor RemoteCommandController {

   private var onEvent: (@Sendable (RemoteCommandEvent) -> Void)?

   public init() {}

   public func configure(onEvent: @escaping @Sendable (RemoteCommandEvent) -> Void) {
      self.onEvent = onEvent

      let capturedOnEvent = onEvent
      let center = MPRemoteCommandCenter.shared()

      center.playCommand.addTarget { _ in
         capturedOnEvent(.play)
         return .success
      }

      center.pauseCommand.addTarget { _ in
         capturedOnEvent(.pause)
         return .success
      }

      center.togglePlayPauseCommand.addTarget { _ in
         capturedOnEvent(.togglePlayPause)
         return .success
      }

      center.changePlaybackPositionCommand.addTarget { event in
         guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
            return .commandFailed
         }
         capturedOnEvent(.changePlaybackPosition(positionEvent.positionTime))
         return .success
      }

      center.skipForwardCommand.preferredIntervals = [NSNumber(value: 10)]
      center.skipForwardCommand.addTarget { event in
         guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
            return .commandFailed
         }
         capturedOnEvent(.skipForward(skipEvent.interval))
         return .success
      }

      center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 10)]
      center.skipBackwardCommand.addTarget { event in
         guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
            return .commandFailed
         }
         capturedOnEvent(.skipBackward(skipEvent.interval))
         return .success
      }
   }

   public func unregister() {
      let center = MPRemoteCommandCenter.shared()
      center.playCommand.removeTarget(nil)
      center.pauseCommand.removeTarget(nil)
      center.togglePlayPauseCommand.removeTarget(nil)
      center.changePlaybackPositionCommand.removeTarget(nil)
      center.skipForwardCommand.removeTarget(nil)
      center.skipBackwardCommand.removeTarget(nil)
   }

   deinit {
      let center = MPRemoteCommandCenter.shared()
      center.playCommand.removeTarget(nil)
      center.pauseCommand.removeTarget(nil)
      center.togglePlayPauseCommand.removeTarget(nil)
      center.changePlaybackPositionCommand.removeTarget(nil)
      center.skipForwardCommand.removeTarget(nil)
      center.skipBackwardCommand.removeTarget(nil)
   }
}
