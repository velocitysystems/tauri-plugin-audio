import AudioPlayerKit
import Tauri
import UIKit

/// Tauri plugin entry point for native iOS audio playback.
///
/// Each `@objc public func` corresponds to a command registered in `build.rs`.
/// Arguments are parsed from the `Invoke` object and delegated to the
/// `AVPlayerAdapter` actor, which serializes all access to AVPlayer and the
/// state machine. All AudioPlayerKit components are plain actors — none
/// require main thread access with iOS 16+ as the deployment target.
///
/// Method names use snake_case to match the Tauri command names from `build.rs`.
/// Swift's `@objc(name:)` renaming doesn't work with `throws` methods (the
/// implicit NSError parameter changes the selector arity), so the Swift
/// identifiers must match the Objective-C selectors directly.
class AudioPlugin: Plugin {

   private let adapter = AVPlayerAdapter()
   private let audioSession = AudioSessionController()
   private let nowPlaying = NowPlayingController()
   private let remoteCommands = RemoteCommandController()

   override init() {
      super.init()

      let adapter = self.adapter
      let audioSession = self.audioSession
      let nowPlaying = self.nowPlaying
      let remoteCommands = self.remoteCommands

      Task {
         await audioSession.configure { [weak adapter, weak nowPlaying] event in
            guard let adapter, let nowPlaying else { return }
            Task {
               await AudioPlugin.handleAudioSessionEvent(
                  event, adapter: adapter, nowPlaying: nowPlaying
               )
            }
         }

         await remoteCommands.configure { [weak adapter, weak nowPlaying] event in
            guard let adapter, let nowPlaying else { return }
            Task {
               await AudioPlugin.handleRemoteCommandEvent(
                  event, adapter: adapter, nowPlaying: nowPlaying
               )
            }
         }
      }

      // Consume state-change events and forward to Tauri plugin listeners
      Task {
         for await snapshot in adapter.stateChanges {
            try? self.trigger("state-changed", data: snapshot)
         }
      }

      // Consume time-update events and forward to Tauri plugin listeners
      Task {
         for await time in adapter.timeUpdates {
            try? self.trigger("time-update", data: time)

            let playbackRate = await adapter.stateMachine.playbackRate
            let isPlaying = await adapter.stateMachine.status == .playing

            await nowPlaying.updateElapsedTime(
               time.currentTime,
               playbackRate: playbackRate,
               isPlaying: isPlaying
            )
         }
      }
   }

   // MARK: - Commands

   @objc public func load(_ invoke: Invoke) throws {
      let args = try invoke.parseArgs(LoadArgs.self)
      let metadata = AudioMetadata(
         title: args.metadata?.title,
         artist: args.metadata?.artist,
         artwork: args.metadata?.artwork
      )

      Task { [adapter, audioSession, nowPlaying] in
         do {
            await audioSession.setActive(true)
            let response = try await adapter.load(src: args.src, metadata: metadata)
            await nowPlaying.update(from: response.player, isPlaying: false)
            invoke.resolve(response)
         } catch {
            invoke.reject(error.localizedDescription)
         }
      }
   }

   @objc public func play(_ invoke: Invoke) throws {
      Task { [adapter, nowPlaying] in
         do {
            let response = try await adapter.play()
            await nowPlaying.update(from: response.player, isPlaying: true)
            invoke.resolve(response)
         } catch {
            invoke.reject(error.localizedDescription)
         }
      }
   }

   @objc public func pause(_ invoke: Invoke) throws {
      Task { [adapter, nowPlaying] in
         do {
            let response = try await adapter.pause()
            await nowPlaying.update(from: response.player, isPlaying: false)
            invoke.resolve(response)
         } catch {
            invoke.reject(error.localizedDescription)
         }
      }
   }

   @objc public func stop(_ invoke: Invoke) throws {
      Task { [adapter, nowPlaying, remoteCommands, audioSession] in
         do {
            let response = try await adapter.stop()
            await nowPlaying.clear()
            await remoteCommands.unregister()
            await audioSession.setActive(false)
            invoke.resolve(response)
         } catch {
            invoke.reject(error.localizedDescription)
         }
      }
   }

   @objc public func seek(_ invoke: Invoke) throws {
      let args = try invoke.parseArgs(SeekArgs.self)

      Task { [adapter, nowPlaying] in
         do {
            let response = try await adapter.seek(position: args.position)
            await nowPlaying.updateElapsedTime(
               response.player.currentTime,
               playbackRate: response.player.playbackRate,
               isPlaying: response.player.status == .playing
            )
            invoke.resolve(response)
         } catch {
            invoke.reject(error.localizedDescription)
         }
      }
   }

   @objc public func set_volume(_ invoke: Invoke) throws {
      let args = try invoke.parseArgs(VolumeArgs.self)

      Task { [adapter] in
         do {
            let state = try await adapter.setVolume(level: args.level)
            invoke.resolve(state)
         } catch {
            invoke.reject(error.localizedDescription)
         }
      }
   }

   @objc public func set_muted(_ invoke: Invoke) throws {
      let args = try invoke.parseArgs(MutedArgs.self)

      Task { [adapter] in
         let state = await adapter.setMuted(args.muted)
         invoke.resolve(state)
      }
   }

   @objc public func set_playback_rate(_ invoke: Invoke) throws {
      let args = try invoke.parseArgs(PlaybackRateArgs.self)

      Task { [adapter] in
         do {
            let state = try await adapter.setPlaybackRate(args.rate)
            invoke.resolve(state)
         } catch {
            invoke.reject(error.localizedDescription)
         }
      }
   }

   @objc public func set_loop(_ invoke: Invoke) throws {
      let args = try invoke.parseArgs(LoopArgs.self)

      Task { [adapter] in
         let state = await adapter.setLoop(args.looping)
         invoke.resolve(state)
      }
   }

   @objc public func get_state(_ invoke: Invoke) throws {
      Task { [adapter] in
         let state = await adapter.state()
         invoke.resolve(state)
      }
   }

   @objc public func is_native(_ invoke: Invoke) throws {
      invoke.resolve(IsNativeResponse(value: true))
   }

   // MARK: - Audio session events

   private static func handleAudioSessionEvent(
      _ event: AudioSessionEvent,
      adapter: AVPlayerAdapter,
      nowPlaying: NowPlayingController
   ) async {
      switch event {
      case .interruptionBegan:
         if await adapter.stateMachine.status == .playing {
            let response = try? await adapter.pause()
            if let snapshot = response?.player {
               await nowPlaying.update(from: snapshot, isPlaying: false)
            }
         }

      case .interruptionEndedShouldResume:
         if await adapter.stateMachine.status == .paused {
            let response = try? await adapter.play()
            if let snapshot = response?.player {
               await nowPlaying.update(from: snapshot, isPlaying: true)
            }
         }

      case .routeChangeOldDeviceUnavailable:
         if await adapter.stateMachine.status == .playing {
            let response = try? await adapter.pause()
            if let snapshot = response?.player {
               await nowPlaying.update(from: snapshot, isPlaying: false)
            }
         }
      }
   }

   // MARK: - Remote command events

   private static func handleRemoteCommandEvent(
      _ event: RemoteCommandEvent,
      adapter: AVPlayerAdapter,
      nowPlaying: NowPlayingController
   ) async {
      switch event {
      case .play:
         let response = try? await adapter.play()
         if let snapshot = response?.player {
            await nowPlaying.update(from: snapshot, isPlaying: true)
         }

      case .pause:
         let response = try? await adapter.pause()
         if let snapshot = response?.player {
            await nowPlaying.update(from: snapshot, isPlaying: false)
         }

      case .togglePlayPause:
         let status = await adapter.stateMachine.status
         if status == .playing {
            let response = try? await adapter.pause()
            if let snapshot = response?.player {
               await nowPlaying.update(from: snapshot, isPlaying: false)
            }
         } else if status == .paused || status == .ready {
            let response = try? await adapter.play()
            if let snapshot = response?.player {
               await nowPlaying.update(from: snapshot, isPlaying: true)
            }
         }

      case .changePlaybackPosition(let position):
         let response = try? await adapter.seek(position: position)
         if let snapshot = response?.player {
            await nowPlaying.updateElapsedTime(
               snapshot.currentTime,
               playbackRate: snapshot.playbackRate,
               isPlaying: snapshot.status == .playing
            )
         }

      case .skipForward(let interval):
         let currentTime = await adapter.stateMachine.currentTime
         let response = try? await adapter.seek(position: currentTime + interval)
         if let snapshot = response?.player {
            await nowPlaying.updateElapsedTime(
               snapshot.currentTime,
               playbackRate: snapshot.playbackRate,
               isPlaying: snapshot.status == .playing
            )
         }

      case .skipBackward(let interval):
         let currentTime = await adapter.stateMachine.currentTime
         let response = try? await adapter.seek(position: currentTime - interval)
         if let snapshot = response?.player {
            await nowPlaying.updateElapsedTime(
               snapshot.currentTime,
               playbackRate: snapshot.playbackRate,
               isPlaying: snapshot.status == .playing
            )
         }
      }
   }
}

// MARK: - Plugin entry point

@_cdecl("init_plugin_audio")
func initPlugin() -> Plugin {
   AudioPlugin()
}

// MARK: - Invoke argument types

private struct LoadArgs: Decodable {
   let src: String
   let metadata: MetadataArgs?
}

private struct MetadataArgs: Decodable {
   let title: String?
   let artist: String?
   let artwork: String?
}

private struct SeekArgs: Decodable {
   let position: Double
}

private struct VolumeArgs: Decodable {
   let level: Double
}

private struct MutedArgs: Decodable {
   let muted: Bool
}

private struct PlaybackRateArgs: Decodable {
   let rate: Double
}

private struct LoopArgs: Decodable {
   let looping: Bool
}

/// Response type for the `is_native` command.
private struct IsNativeResponse: Encodable {
   let value: Bool
}
