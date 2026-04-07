import AVFoundation
import Foundation

/// Callback for audio session events that require state machine transitions.
public enum AudioSessionEvent: Sendable {
   case interruptionBegan
   case interruptionEndedShouldResume
   case routeChangeOldDeviceUnavailable
}

/// Manages AVAudioSession configuration for background audio playback.
///
/// Configures the `.playback` category, handles audio interruptions (phone calls,
/// Siri, etc.), and route changes (headphone disconnect). AVAudioSession is
/// thread-safe, so a plain actor is sufficient for serialization.
public actor AudioSessionController {

   private var onEvent: (@Sendable (AudioSessionEvent) -> Void)?
   private var interruptionObserver: NSObjectProtocol?
   private var routeChangeObserver: NSObjectProtocol?

   public init() {}

   public func configure(onEvent: @escaping @Sendable (AudioSessionEvent) -> Void) {
      self.onEvent = onEvent

      let session = AVAudioSession.sharedInstance()
      do {
         try session.setCategory(.playback, mode: .default)
      } catch {
         NSLog("[AudioSessionController] Failed to set audio session category: \(error)")
      }

      let capturedOnEvent = onEvent

      interruptionObserver = NotificationCenter.default.addObserver(
         forName: AVAudioSession.interruptionNotification,
         object: session,
         queue: nil
      ) { notification in
         guard let userInfo = notification.userInfo,
               let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
               let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
         }

         switch type {
         case .began:
            capturedOnEvent(.interruptionBegan)

         case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
               capturedOnEvent(.interruptionEndedShouldResume)
            }

         @unknown default:
            break
         }
      }

      routeChangeObserver = NotificationCenter.default.addObserver(
         forName: AVAudioSession.routeChangeNotification,
         object: session,
         queue: nil
      ) { notification in
         guard let userInfo = notification.userInfo,
               let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
               let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
         }

         if reason == .oldDeviceUnavailable {
            capturedOnEvent(.routeChangeOldDeviceUnavailable)
         }
      }
   }

   public func setActive(_ active: Bool) {
      do {
         try AVAudioSession.sharedInstance().setActive(active, options: .notifyOthersOnDeactivation)
      } catch {
         NSLog("[AudioSessionController] Failed to set active(\(active)): \(error)")
      }
   }

   public func teardown() {
      if let observer = interruptionObserver {
         NotificationCenter.default.removeObserver(observer)
         interruptionObserver = nil
      }
      if let observer = routeChangeObserver {
         NotificationCenter.default.removeObserver(observer)
         routeChangeObserver = nil
      }
      setActive(false)
   }

   deinit {
      if let observer = interruptionObserver {
         NotificationCenter.default.removeObserver(observer)
      }
      if let observer = routeChangeObserver {
         NotificationCenter.default.removeObserver(observer)
      }
   }
}
