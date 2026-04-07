// Desktop and Android model types — re-exported from the audio-player crate.
#[cfg(not(target_os = "ios"))]
pub use audio_player::models::{AudioActionResponse, AudioMetadata, PlayerState};

// iOS model types — equivalent definitions for deserialization of native plugin
// responses. Must produce the same JSON shapes as the Rust types.
#[cfg(target_os = "ios")]
mod ios_types {
   use serde::{Deserialize, Serialize};

   #[derive(Serialize)]
   #[serde(rename_all = "camelCase")]
   pub struct LoadArgs {
      pub src: String,
      pub metadata: Option<AudioMetadata>,
   }

   #[derive(Serialize)]
   #[serde(rename_all = "camelCase")]
   pub struct SeekArgs {
      pub position: f64,
   }

   #[derive(Serialize)]
   #[serde(rename_all = "camelCase")]
   pub struct VolumeArgs {
      pub level: f64,
   }

   #[derive(Serialize)]
   #[serde(rename_all = "camelCase")]
   pub struct MutedArgs {
      pub muted: bool,
   }

   #[derive(Serialize)]
   #[serde(rename_all = "camelCase")]
   pub struct PlaybackRateArgs {
      pub rate: f64,
   }

   #[derive(Serialize)]
   #[serde(rename_all = "camelCase")]
   pub struct LoopArgs {
      pub looping: bool,
   }

   #[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
   #[serde(rename_all = "camelCase")]
   pub enum PlaybackStatus {
      #[default]
      Idle,
      Loading,
      Ready,
      Playing,
      Paused,
      Ended,
      Error,
   }

   #[derive(Debug, Clone, Default, Serialize, Deserialize)]
   #[serde(rename_all = "camelCase")]
   pub struct AudioMetadata {
      pub title: Option<String>,
      pub artist: Option<String>,
      pub artwork: Option<String>,
   }

   #[derive(Debug, Clone, Serialize, Deserialize)]
   #[serde(rename_all = "camelCase")]
   pub struct PlayerState {
      pub status: PlaybackStatus,
      pub src: Option<String>,
      pub title: Option<String>,
      pub artist: Option<String>,
      pub artwork: Option<String>,
      pub current_time: f64,
      pub duration: f64,
      pub volume: f64,
      pub muted: bool,
      pub playback_rate: f64,
      #[serde(rename = "loop")]
      pub looping: bool,
      pub error: Option<String>,
   }

   #[derive(Debug, Clone, Serialize, Deserialize)]
   #[serde(rename_all = "camelCase")]
   pub struct AudioActionResponse {
      pub player: PlayerState,
      pub expected_status: PlaybackStatus,
      pub is_expected_status: bool,
   }
}

#[cfg(target_os = "ios")]
pub use ios_types::{
   AudioActionResponse, AudioMetadata, LoadArgs, LoopArgs, MutedArgs, PlaybackRateArgs,
   PlayerState, SeekArgs, VolumeArgs,
};
