import Foundation
import MediaPlayer
import UIKit

/// Manages the MPNowPlayingInfoCenter for lock screen and Control Center metadata.
///
/// Updates title, artist, duration, elapsed time, playback rate, and artwork.
/// Artwork is fetched asynchronously with UUID-based cancellation to avoid
/// stale images when the track changes.
public actor NowPlayingController {

   /// UUID of the current artwork fetch. Used to cancel stale fetches.
   private var artworkFetchID: UUID?

   public init() {}

   /// Updates Now Playing info from a player state snapshot.
   public func update(from state: PlayerStateSnapshot, isPlaying: Bool) {
      var info = [String: Any]()

      info[MPMediaItemPropertyTitle] = state.title ?? appDisplayName()
      info[MPMediaItemPropertyArtist] = state.artist ?? ""
      info[MPMediaItemPropertyPlaybackDuration] = state.duration
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.currentTime
      info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? state.playbackRate : 0.0
      info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = state.playbackRate

      MPNowPlayingInfoCenter.default().nowPlayingInfo = info

      if let artworkURLString = state.artwork,
         let artworkURL = URL(string: artworkURLString) {
         fetchArtwork(from: artworkURL)
      } else {
         artworkFetchID = nil
      }
   }

   /// Updates only the elapsed time and playback rate (for time-update ticks).
   public func updateElapsedTime(_ currentTime: Double, playbackRate: Double, isPlaying: Bool) {
      guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }

      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
      info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0

      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
   }

   /// Clears Now Playing info (called on stop).
   public func clear() {
      artworkFetchID = nil
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
   }

   // MARK: - Private

   private func fetchArtwork(from url: URL) {
      let fetchID = UUID()
      artworkFetchID = fetchID

      Task { [weak self] in
         guard let (data, _) = try? await URLSession.shared.data(from: url),
               let self,
               await self.artworkFetchID == fetchID,
               let image = UIImage(data: data) else {
            return
         }

         await self.applyArtwork(image, fetchID: fetchID)
      }
   }

   private func applyArtwork(_ image: UIImage, fetchID: UUID) {
      guard artworkFetchID == fetchID else { return }

      let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

      guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
      info[MPMediaItemPropertyArtwork] = artwork
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
   }

   private nonisolated func appDisplayName() -> String {
      return Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
         ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
         ?? ""
   }
}
