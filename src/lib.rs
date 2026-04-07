use tauri::{
   Manager, Runtime,
   plugin::{Builder, TauriPlugin},
};

#[cfg(not(target_os = "ios"))]
use std::sync::Arc;

#[cfg(not(target_os = "ios"))]
use tauri::Emitter;
#[cfg(not(target_os = "ios"))]
use tracing::warn;

mod commands;
mod error;
mod models;

pub use error::Result;
pub use models::{AudioActionResponse, AudioMetadata, PlayerState};

#[cfg(not(target_os = "ios"))]
pub use audio_player::{OnChanged, OnTimeUpdate, RodioAudioPlayer};

#[cfg(target_os = "ios")]
mod mobile;
#[cfg(target_os = "ios")]
use mobile::Audio;

/// Extensions to [`tauri::App`], [`tauri::AppHandle`] and [`tauri::Window`] to access
/// the audio player APIs.
///
/// The trait is split by platform because the return type differs:
/// - Desktop and Android use the Tauri-agnostic `RodioAudioPlayer` (Rust implementation).
/// - iOS delegates to the native AVFoundation plugin via a `PluginHandle`, so the return
///   type carries the `R: Runtime` generic required by Tauri's mobile plugin bridge.
#[cfg(not(target_os = "ios"))]
pub trait AudioExt<R: Runtime> {
   fn audio(&self) -> &RodioAudioPlayer;
}

#[cfg(target_os = "ios")]
pub trait AudioExt<R: Runtime> {
   fn audio(&self) -> &Audio<R>;
}

#[cfg(not(target_os = "ios"))]
impl<R: Runtime, T: Manager<R>> AudioExt<R> for T {
   fn audio(&self) -> &RodioAudioPlayer {
      self.state::<RodioAudioPlayer>().inner()
   }
}

#[cfg(target_os = "ios")]
impl<R: Runtime, T: Manager<R>> AudioExt<R> for T {
   fn audio(&self) -> &Audio<R> {
      self.state::<Audio<R>>().inner()
   }
}

/// Initializes the audio plugin.
///
/// On desktop and Android, opens the default audio output device with Rodio-backed
/// playback. On iOS, registers the native AVFoundation plugin.
pub fn init<R: Runtime>() -> TauriPlugin<R> {
   Builder::new("audio")
      .invoke_handler(tauri::generate_handler![
         commands::load,
         commands::play,
         commands::pause,
         commands::stop,
         commands::seek,
         commands::set_volume,
         commands::set_muted,
         commands::set_playback_rate,
         commands::set_loop,
         commands::get_state,
         commands::is_native,
      ])
      .setup(|app, _api| {
         #[cfg(not(target_os = "ios"))]
         {
            let state_handle = app.clone();
            let time_handle = app.clone();

            let player = RodioAudioPlayer::new(
               Arc::new(move |state| {
                  if let Err(e) = state_handle.emit("tauri-plugin-audio:state-changed", state) {
                     warn!("Failed to emit state-changed event: {}", e);
                  }
               }),
               Arc::new(move |time| {
                  if let Err(e) = time_handle.emit("tauri-plugin-audio:time-update", time) {
                     warn!("Failed to emit time-update event: {}", e);
                  }
               }),
            )
            .map_err(|e| e.to_string())?;

            app.manage(player);
         }

         #[cfg(target_os = "ios")]
         {
            let audio = mobile::init(app, _api)?;
            app.manage(audio);
         }

         Ok(())
      })
      .build()
}
