use serde::de::DeserializeOwned;
use tauri::plugin::{PluginApi, PluginHandle};
use tauri::{AppHandle, Runtime};

use crate::models::*;

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_audio);

pub fn init<R: Runtime, C: DeserializeOwned>(
   _app: &AppHandle<R>,
   _api: PluginApi<R, C>,
) -> crate::Result<Audio<R>> {
   #[cfg(target_os = "android")]
   let handle = _api.register_android_plugin("com.silvermine.tauri_plugin_audio", "AudioPlugin")?;
   #[cfg(target_os = "ios")]
   let handle = _api.register_ios_plugin(init_plugin_audio)?;
   Ok(Audio(handle))
}

/// Access to the audio APIs on mobile platforms.
///
/// Delegates commands to the native Swift (iOS) or Kotlin (Android) implementation
/// via Tauri's `PluginHandle`.
pub struct Audio<R: Runtime>(PluginHandle<R>);

impl<R: Runtime> Audio<R> {
   pub fn load(
      &self,
      src: &str,
      metadata: Option<AudioMetadata>,
   ) -> crate::Result<AudioActionResponse> {
      self
         .0
         .run_mobile_plugin(
            "load",
            LoadArgs {
               src: src.to_string(),
               metadata,
            },
         )
         .map_err(Into::into)
   }

   pub fn play(&self) -> crate::Result<AudioActionResponse> {
      self.0.run_mobile_plugin("play", ()).map_err(Into::into)
   }

   pub fn pause(&self) -> crate::Result<AudioActionResponse> {
      self.0.run_mobile_plugin("pause", ()).map_err(Into::into)
   }

   pub fn stop(&self) -> crate::Result<AudioActionResponse> {
      self.0.run_mobile_plugin("stop", ()).map_err(Into::into)
   }

   pub fn seek(&self, position: f64) -> crate::Result<AudioActionResponse> {
      self
         .0
         .run_mobile_plugin("seek", SeekArgs { position })
         .map_err(Into::into)
   }

   pub fn set_volume(&self, level: f64) -> crate::Result<PlayerState> {
      self
         .0
         .run_mobile_plugin("set_volume", VolumeArgs { level })
         .map_err(Into::into)
   }

   pub fn set_muted(&self, muted: bool) -> crate::Result<PlayerState> {
      self
         .0
         .run_mobile_plugin("set_muted", MutedArgs { muted })
         .map_err(Into::into)
   }

   pub fn set_playback_rate(&self, rate: f64) -> crate::Result<PlayerState> {
      self
         .0
         .run_mobile_plugin("set_playback_rate", PlaybackRateArgs { rate })
         .map_err(Into::into)
   }

   pub fn set_loop(&self, looping: bool) -> crate::Result<PlayerState> {
      self
         .0
         .run_mobile_plugin("set_loop", LoopArgs { looping })
         .map_err(Into::into)
   }

   pub fn get_state(&self) -> crate::Result<PlayerState> {
      self
         .0
         .run_mobile_plugin("get_state", ())
         .map_err(Into::into)
   }
}
