// Desktop and Android error types — re-exported from the audio-player crate.
#[cfg(not(target_os = "ios"))]
#[allow(unused_imports)]
pub use audio_player::{Error, Result};

// iOS error types
#[cfg(target_os = "ios")]
mod ios_error {
   use serde::{Serialize, ser::Serializer};

   pub type Result<T> = std::result::Result<T, Error>;

   #[derive(Debug, thiserror::Error)]
   pub enum Error {
      #[error(transparent)]
      PluginInvoke(#[from] tauri::plugin::mobile::PluginInvokeError),
   }

   impl Serialize for Error {
      fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
      where
         S: Serializer,
      {
         serializer.serialize_str(self.to_string().as_ref())
      }
   }
}

#[cfg(target_os = "ios")]
pub use ios_error::Result;
