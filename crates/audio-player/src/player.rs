use std::io::{Cursor, Read};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;

use rodio::{Decoder, OutputStream, OutputStreamHandle, Sink, Source};
use tracing::warn;

use crate::error::{Error, Result};
use crate::models::{
   AudioActionResponse, LoopMode, PlaybackStatus, PlayerState, PlaylistItem, TimeUpdate,
};
use crate::net::reject_private_host;
use crate::transitions::NavTarget;
use crate::{OnChanged, OnTimeUpdate, transitions};

/// Maximum audio download size (100 MiB).
const MAX_DOWNLOAD_BYTES: u64 = 100 * 1024 * 1024;

/// HTTP request timeout (connect + read combined).
const HTTP_TIMEOUT: Duration = Duration::from_secs(30);

/// Audio player backed by Rodio for cross-platform desktop playback.
///
/// Manages a dedicated audio output thread, a playback monitor for time updates
/// and end-of-track auto-advance, and a state machine matching the plugin's
/// [`PlaybackStatus`] model.
///
/// Construct with [`RodioAudioPlayer::new`], which returns an `Arc` so the
/// monitor thread can hold a weak self-reference for auto-advance callbacks.
pub struct RodioAudioPlayer {
   inner: Arc<Mutex<Inner>>,
   stream_handle: OutputStreamHandle,
   /// Dropping this sender signals the audio output thread to exit.
   _stream_keep_alive: std::sync::mpsc::Sender<()>,
   on_changed: OnChanged,
   on_time_update: OnTimeUpdate,
   /// Weak self-reference so the monitor thread can call back without
   /// keeping the player alive after its owner has dropped it.
   weak_self: Weak<Self>,
}

struct Inner {
   state: PlayerState,
   playback: Option<PlaybackContext>,
   monitor_stop: Arc<AtomicBool>,
}

struct PlaybackContext {
   sink: Sink,
   /// Raw audio bytes for the current item, kept for looping re-append and
   /// replay from `Ended`. `Arc` so re-append clones are cheap reference
   /// count bumps instead of multi-megabyte copies.
   source_data: Arc<[u8]>,
   duration: f64,
}

impl RodioAudioPlayer {
   /// Creates a new Rodio-backed audio player.
   ///
   /// Opens the default audio output device on a dedicated thread. Returns an
   /// error if no audio device is available.
   pub fn new(on_changed: OnChanged, on_time_update: OnTimeUpdate) -> Result<Arc<Self>> {
      let stream_handle = open_audio_output()?;

      Ok(Arc::new_cyclic(|weak_self| Self {
         inner: Arc::new(Mutex::new(Inner {
            state: PlayerState::default(),
            playback: None,
            monitor_stop: Arc::new(AtomicBool::new(true)),
         })),
         stream_handle: stream_handle.handle,
         _stream_keep_alive: stream_handle.keep_alive,
         on_changed,
         on_time_update,
         weak_self: weak_self.clone(),
      }))
   }

   fn stop_monitor(inner: &Inner) {
      inner.monitor_stop.store(true, Ordering::Relaxed);
   }

   /// Emits a `state-changed` event with per-item `artwork` data stripped
   /// from the playlist payload.
   fn emit_state_changed(&self, snapshot: &PlayerState) {
      let mut stripped = snapshot.clone();

      for item in stripped.playlist.iter_mut() {
         if let Some(meta) = item.metadata.as_mut() {
            meta.artwork = None;
         }
      }
      (self.on_changed)(&stripped);
   }

   /// Spawns a new monitor thread for time updates and end-of-track detection.
   ///
   /// The old monitor thread may briefly overlap (up to 250ms) until it
   /// observes the stop flag on its next poll. This is harmless — any
   /// duplicate time updates are benign, and the state is already updated
   /// under the mutex before the new monitor starts, so the old one cannot
   /// trigger a spurious advance.
   fn start_monitor(&self, inner: &mut Inner) {
      let stop = Arc::new(AtomicBool::new(false));
      inner.monitor_stop = stop.clone();

      let Some(player) = self.weak_self.upgrade() else {
         warn!("Cannot start monitor: player has been dropped");
         return;
      };

      if let Err(e) = std::thread::Builder::new()
         .name("audio-monitor".into())
         .spawn(move || {
            monitor_loop(stop, player);
         })
      {
         warn!("Failed to spawn audio monitor thread: {e}");
      }
   }

   pub fn get_state(&self) -> PlayerState {
      lock_inner(&self.inner).state.clone()
   }

   /// Loads a playlist and prepares the chosen (or first) item for playback.
   pub fn load(
      &self,
      playlist: Vec<PlaylistItem>,
      start_index: Option<usize>,
   ) -> Result<AudioActionResponse> {
      let start_index = start_index.unwrap_or(0);

      // Transition to Loading and notify the frontend before starting I/O.
      let item_src = {
         let mut inner = lock_inner(&self.inner);
         transitions::begin_load(&mut inner.state, playlist, start_index)?;
         let src = inner
            .state
            .current()
            .map(|item| item.src.clone())
            .ok_or_else(|| Error::InvalidState("Missing current item after begin_load".into()))?;
         let snapshot = inner.state.clone();
         drop(inner);
         self.emit_state_changed(&snapshot);
         src
      };

      // Perform I/O, decoding, and sink creation. If any step fails,
      // transition to Error so the frontend can recover from the Loading state.
      match self.load_inner(&item_src) {
         Ok(snapshot) => {
            self.emit_state_changed(&snapshot);
            Ok(AudioActionResponse::new(snapshot, PlaybackStatus::Ready))
         }
         Err(e) => {
            let snapshot = {
               let mut inner = lock_inner(&self.inner);
               transitions::error(&mut inner.state, e.to_string());
               inner.state.clone()
            };
            self.emit_state_changed(&snapshot);
            Err(e)
         }
      }
   }

   /// Inner load logic that performs I/O for an already-set current item and
   /// finalizes the state to `Ready`. Used by `load`, `next`, `prev`, and
   /// auto-advance.
   fn load_inner(&self, src: &str) -> Result<PlayerState> {
      let data: Arc<[u8]> = load_source_data(src)?.into();

      let source = Decoder::new(Cursor::new(Arc::clone(&data)))
         .map_err(|e| Error::Audio(format!("Failed to decode audio: {e}")))?;
      let duration = source
         .total_duration()
         .map(|d| d.as_secs_f64())
         .unwrap_or_else(|| probe_duration(&data).unwrap_or(0.0));

      let extracted_metadata = crate::metadata::extract(&data);

      let sink = Sink::try_new(&self.stream_handle)
         .map_err(|e| Error::Audio(format!("Failed to create audio sink: {e}")))?;
      sink.pause();
      sink.append(source);

      let mut inner = lock_inner(&self.inner);

      // Enrich the active playlist item's metadata with anything we found
      // in the file (caller-supplied fields win per-field). Done before
      // transitions::load so the Ready state-changed event already carries
      // the merged metadata.
      if let Some(idx) = inner.state.current_index
         && let Some(item) = inner.state.playlist.get_mut(idx)
      {
         let merged = crate::metadata::merge(item.metadata.take(), extracted_metadata);
         item.metadata = Some(merged);
      }

      transitions::load(&mut inner.state, duration)?;

      Self::stop_monitor(&inner);

      sink.set_volume(effective_volume(&inner.state));
      sink.set_speed(inner.state.playback_rate as f32);

      // Drop any existing context (previous item) before installing the new one.
      if let Some(prev) = inner.playback.take() {
         prev.sink.stop();
      }

      inner.playback = Some(PlaybackContext {
         sink,
         source_data: data,
         duration,
      });

      Ok(inner.state.clone())
   }

   pub fn play(&self) -> Result<AudioActionResponse> {
      let snapshot = {
         let mut inner = lock_inner(&self.inner);
         let is_ended = inner.state.status == PlaybackStatus::Ended;

         if is_ended
            && let Some(ctx) = &inner.playback
            && ctx.sink.empty()
            && let Some(source) = decode_arc(&ctx.source_data)
         {
            ctx.sink.append(source);
         }

         transitions::play(&mut inner.state)?;

         if is_ended {
            inner.state.current_time = 0.0;
         }

         if let Some(ctx) = &inner.playback {
            ctx.sink.play();
         }

         self.start_monitor(&mut inner);
         inner.state.clone()
      };

      self.emit_state_changed(&snapshot);
      Ok(AudioActionResponse::new(snapshot, PlaybackStatus::Playing))
   }

   pub fn pause(&self) -> Result<AudioActionResponse> {
      let snapshot = {
         let mut inner = lock_inner(&self.inner);

         transitions::pause(&mut inner.state)?;

         if let Some(ctx) = &inner.playback {
            ctx.sink.pause();
         }

         Self::stop_monitor(&inner);
         inner.state.clone()
      };

      self.emit_state_changed(&snapshot);
      Ok(AudioActionResponse::new(snapshot, PlaybackStatus::Paused))
   }

   pub fn stop(&self) -> Result<AudioActionResponse> {
      let snapshot = {
         let mut inner = lock_inner(&self.inner);

         transitions::stop(&mut inner.state)?;

         Self::stop_monitor(&inner);

         if let Some(ctx) = inner.playback.take() {
            ctx.sink.stop();
         }

         inner.state.clone()
      };

      self.emit_state_changed(&snapshot);
      Ok(AudioActionResponse::new(snapshot, PlaybackStatus::Idle))
   }

   pub fn seek(&self, position: f64) -> Result<AudioActionResponse> {
      let snapshot = {
         let mut inner = lock_inner(&self.inner);
         let was_ended = inner.state.status == PlaybackStatus::Ended;

         transitions::seek(&mut inner.state, position)?;

         if let Some(ctx) = &inner.playback {
            if was_ended {
               if let Some(source) = decode_arc(&ctx.source_data) {
                  ctx.sink.append(source);
               }
               ctx.sink.pause();
            }

            if let Err(e) = ctx
               .sink
               .try_seek(Duration::from_secs_f64(inner.state.current_time))
            {
               warn!("Seek failed: {e}");
            }
         }

         inner.state.clone()
      };

      let expected = snapshot.status;
      self.emit_state_changed(&snapshot);
      Ok(AudioActionResponse::new(snapshot, expected))
   }

   /// Advance to the next playlist item, with wrap-around if `loopMode` is `All`.
   /// Errors with `InvalidState` from `Idle` / `Loading` / `Error`.
   pub fn next(&self) -> Result<AudioActionResponse> {
      self.navigate(Direction::Next)
   }

   /// Move to the previous item, or restart the current item if `currentTime > 3s`
   /// or we're at the start of a non-looping playlist.
   pub fn prev(&self) -> Result<AudioActionResponse> {
      self.navigate(Direction::Prev)
   }

   /// Jump to a specific item in the loaded playlist by index.
   ///
   /// Errors with `InvalidState` from `Idle` / `Loading` / `Error` and with
   /// `InvalidValue` if the index is out of range. Jumping to the currently
   /// active index restarts that item from the beginning.
   pub fn jump_to(&self, index: usize) -> Result<AudioActionResponse> {
      let target = {
         let inner = lock_inner(&self.inner);
         transitions::jump_target(&inner.state, index)?
      };

      match target {
         NavTarget::Index(idx) => self.advance_to(idx),
         NavTarget::RestartCurrent => self.seek(0.0),
         NavTarget::End => self.transition_to_ended(),
      }
   }

   fn navigate(&self, direction: Direction) -> Result<AudioActionResponse> {
      let target = {
         let inner = lock_inner(&self.inner);
         match direction {
            Direction::Next => transitions::next_target(&inner.state)?,
            Direction::Prev => transitions::prev_target(&inner.state)?,
         }
      };

      match target {
         NavTarget::Index(index) => self.advance_to(index),
         NavTarget::RestartCurrent => self.seek(0.0),
         NavTarget::End => self.transition_to_ended(),
      }
   }

   /// Loads `playlist[index]` while preserving play intent — if the player was
   /// `Playing` before the call, it resumes playing the new item once loaded.
   ///
   /// Always emits a `Loading` state-changed event before fetching, even when
   /// the source bytes are already cached. The cache makes the Loading window
   /// effectively instantaneous, but the event is preserved so consumers see
   /// identical state-machine emissions on desktop and on native mobile
   /// platforms (iOS AVPlayer / Android ExoPlayer always emit Loading).
   fn advance_to(&self, index: usize) -> Result<AudioActionResponse> {
      let (was_playing, item_src) = {
         let mut inner = lock_inner(&self.inner);
         let was_playing = inner.state.status == PlaybackStatus::Playing;

         transitions::begin_load_index(&mut inner.state, index)?;

         let src = inner
            .state
            .current()
            .map(|item| item.src.clone())
            .ok_or_else(|| Error::InvalidState("Missing current item after begin_load".into()))?;

         Self::stop_monitor(&inner);
         if let Some(ctx) = inner.playback.take() {
            ctx.sink.stop();
         }

         let snapshot = inner.state.clone();
         drop(inner);
         self.emit_state_changed(&snapshot);
         (was_playing, src)
      };

      let ready_snapshot = match self.load_inner(&item_src) {
         Ok(snapshot) => {
            self.emit_state_changed(&snapshot);
            snapshot
         }
         Err(e) => {
            let snapshot = {
               let mut inner = lock_inner(&self.inner);
               transitions::error(&mut inner.state, e.to_string());
               inner.state.clone()
            };
            self.emit_state_changed(&snapshot);
            return Err(e);
         }
      };

      if was_playing {
         self.play()
      } else {
         Ok(AudioActionResponse::new(
            ready_snapshot,
            PlaybackStatus::Ready,
         ))
      }
   }

   /// Transitions to `Ended` when navigation falls off the end of a non-looping
   /// playlist.
   fn transition_to_ended(&self) -> Result<AudioActionResponse> {
      let snapshot = {
         let mut inner = lock_inner(&self.inner);

         transitions::ended(&mut inner.state);

         Self::stop_monitor(&inner);
         if let Some(ctx) = &inner.playback {
            ctx.sink.pause();
         }

         inner.state.clone()
      };

      self.emit_state_changed(&snapshot);
      Ok(AudioActionResponse::new(snapshot, PlaybackStatus::Ended))
   }

   pub fn set_volume(&self, level: f64) -> Result<PlayerState> {
      let snapshot = {
         let mut inner = lock_inner(&self.inner);
         transitions::set_volume(&mut inner.state, level)?;
         if let Some(ctx) = &inner.playback {
            ctx.sink.set_volume(effective_volume(&inner.state));
         }
         inner.state.clone()
      };

      self.emit_state_changed(&snapshot);
      Ok(snapshot)
   }

   pub fn set_muted(&self, muted: bool) -> PlayerState {
      let snapshot = {
         let mut inner = lock_inner(&self.inner);
         transitions::set_muted(&mut inner.state, muted);
         if let Some(ctx) = &inner.playback {
            ctx.sink.set_volume(effective_volume(&inner.state));
         }
         inner.state.clone()
      };

      self.emit_state_changed(&snapshot);
      snapshot
   }

   pub fn set_playback_rate(&self, rate: f64) -> Result<PlayerState> {
      let snapshot = {
         let mut inner = lock_inner(&self.inner);
         transitions::set_playback_rate(&mut inner.state, rate)?;
         if let Some(ctx) = &inner.playback {
            ctx.sink.set_speed(inner.state.playback_rate as f32);
         }
         inner.state.clone()
      };

      self.emit_state_changed(&snapshot);
      Ok(snapshot)
   }

   pub fn set_loop_mode(&self, mode: LoopMode) -> PlayerState {
      let snapshot = {
         let mut inner = lock_inner(&self.inner);
         transitions::set_loop_mode(&mut inner.state, mode);
         inner.state.clone()
      };

      self.emit_state_changed(&snapshot);
      snapshot
   }
}

#[derive(Copy, Clone)]
enum Direction {
   Next,
   Prev,
}

// ---------------------------------------------------------------------------
// Audio output thread
// ---------------------------------------------------------------------------

struct AudioOutput {
   handle: OutputStreamHandle,
   keep_alive: std::sync::mpsc::Sender<()>,
}

/// Opens the default audio output device on a dedicated thread.
///
/// The [`OutputStream`] must remain on the thread that created it (platform
/// requirement on some backends). We keep it alive via a channel — dropping the
/// returned sender signals the thread to exit.
fn open_audio_output() -> Result<AudioOutput> {
   let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
   let (keep_alive_tx, keep_alive_rx) = std::sync::mpsc::channel::<()>();

   std::thread::Builder::new()
      .name("audio-output".into())
      .spawn(move || match OutputStream::try_default() {
         Ok((_stream, handle)) => {
            let _ = result_tx.send(Ok(handle));
            let _ = keep_alive_rx.recv();
         }
         Err(e) => {
            let _ = result_tx.send(Err(e));
         }
      })
      .map_err(|e| Error::Audio(format!("Failed to spawn audio thread: {e}")))?;

   let handle = result_rx
      .recv()
      .map_err(|_| Error::Audio("Audio thread terminated unexpectedly".into()))?
      .map_err(|e| Error::Audio(format!("Failed to open audio device: {e}")))?;

   Ok(AudioOutput {
      handle,
      keep_alive: keep_alive_tx,
   })
}

// ---------------------------------------------------------------------------
// Playback monitor
// ---------------------------------------------------------------------------

/// Polls the sink every 250ms for position updates and end-of-track detection.
///
/// On end-of-track, consults [`transitions::auto_advance_target`] to decide
/// whether to restart the current item, advance to the next item, or
/// transition to `Ended`.
fn monitor_loop(stop: Arc<AtomicBool>, player: Arc<RodioAudioPlayer>) {
   loop {
      std::thread::sleep(Duration::from_millis(250));

      if stop.load(Ordering::Relaxed) {
         break;
      }

      let mut guard = lock_inner(&player.inner);

      let (pos, duration, is_empty) = match &guard.playback {
         Some(ctx) => (
            ctx.sink.get_pos().as_secs_f64(),
            ctx.duration,
            ctx.sink.empty(),
         ),
         None => break,
      };

      if is_empty {
         let target = transitions::auto_advance_target(&guard.state);
         match target {
            NavTarget::RestartCurrent => {
               if let Some(ctx) = &guard.playback
                  && let Some(source) = decode_arc(&ctx.source_data)
               {
                  ctx.sink.append(source);
               }
               guard.state.current_time = 0.0;
               drop(guard);
               (player.on_time_update)(&TimeUpdate {
                  current_time: 0.0,
                  duration,
               });
            }
            NavTarget::Index(idx) => {
               // Drop the lock before invoking `advance_to` (which re-acquires).
               drop(guard);
               if let Err(e) = player.advance_to(idx) {
                  warn!("Auto-advance failed: {e}");
               }
               // `advance_to` (via `play`) starts a fresh monitor; this one exits.
               break;
            }
            NavTarget::End => {
               transitions::ended(&mut guard.state);
               let snapshot = guard.state.clone();
               drop(guard);
               player.emit_state_changed(&snapshot);
               break;
            }
         }
      } else {
         guard.state.current_time = pos;
         drop(guard);
         (player.on_time_update)(&TimeUpdate {
            current_time: pos,
            duration,
         });
      }
   }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Acquires the mutex, recovering from poisoning instead of panicking.
///
/// A poisoned mutex means a thread panicked while holding the lock. The inner
/// data may be in an inconsistent state, but for an audio player the worst case
/// is a glitched playback state — far better than crashing the host application.
fn lock_inner(mutex: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
   mutex.lock().unwrap_or_else(|e| e.into_inner())
}

/// Creates a new decoder from shared audio data (cheap Arc clone, no byte copy).
fn decode_arc(data: &Arc<[u8]>) -> Option<Decoder<Cursor<Arc<[u8]>>>> {
   Decoder::new(Cursor::new(Arc::clone(data))).ok()
}

/// Resolves the effective sink volume, accounting for the mute flag.
fn effective_volume(state: &PlayerState) -> f32 {
   if state.muted {
      0.0
   } else {
      state.volume as f32
   }
}

/// Probes audio data with symphonia to determine duration from container metadata.
fn probe_duration(data: &Arc<[u8]>) -> Option<f64> {
   use symphonia::core::formats::FormatOptions;
   use symphonia::core::io::MediaSourceStream;
   use symphonia::core::meta::MetadataOptions;
   use symphonia::core::probe::Hint;

   let cursor = Cursor::new(Arc::clone(data));
   let mss = MediaSourceStream::new(Box::new(cursor), Default::default());

   let probed = symphonia::default::get_probe()
      .format(
         &Hint::new(),
         mss,
         &FormatOptions::default(),
         &MetadataOptions::default(),
      )
      .ok()?;

   let track = probed.format.default_track()?;
   let time_base = track.codec_params.time_base?;
   let n_frames = track.codec_params.n_frames?;
   let time = time_base.calc_time(n_frames);

   Some(time.seconds as f64 + time.frac)
}

/// Loads raw audio bytes from a file path or HTTP(S) URL.
fn load_source_data(src: &str) -> Result<Vec<u8>> {
   if src.starts_with("http://") || src.starts_with("https://") {
      reject_private_host(src)?;

      let resp = ureq::AgentBuilder::new()
         .timeout(HTTP_TIMEOUT)
         .redirects(0)
         .build()
         .get(src)
         .call()
         .map_err(|e| Error::Http(format!("Failed to fetch {src}: {e}")))?;

      if let Some(len) = resp
         .header("content-length")
         .and_then(|v| v.parse::<u64>().ok())
         && len > MAX_DOWNLOAD_BYTES
      {
         return Err(Error::Http(format!(
            "Response too large ({len} bytes, max {MAX_DOWNLOAD_BYTES})"
         )));
      }

      let mut bytes = Vec::new();
      resp
         .into_reader()
         .take(MAX_DOWNLOAD_BYTES + 1)
         .read_to_end(&mut bytes)
         .map_err(Error::Io)?;

      if bytes.len() as u64 > MAX_DOWNLOAD_BYTES {
         return Err(Error::Http(format!(
            "Response exceeded maximum size of {MAX_DOWNLOAD_BYTES} bytes"
         )));
      }

      Ok(bytes)
   } else {
      if src.contains("://") || src.starts_with("data:") {
         return Err(Error::Http(format!("Unsupported URL scheme: {src}")));
      }
      std::fs::read(src).map_err(Error::Io)
   }
}
