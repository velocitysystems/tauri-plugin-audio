# Native Mobile Audio Implementation Plan

Implementation plan for adding native iOS (AVFoundation) and Android
(Media3 ExoPlayer) audio support to `tauri-plugin-audio`, informed by
analysis of `tauri-plugin-native-audio` (v1.0.5).

## Reference crate

`uvarov-frontend/tauri-plugin-native-audio` provides a working iOS +
Android implementation. This plan adopts its structural patterns and OS
integration code while replacing its state model, adding missing
features, and fixing identified shortcomings.

---

## Table of contents

1. [Design decisions](#1-design-decisions)
2. [Shortcomings of the reference crate](#2-shortcomings-of-the-reference-crate)
3. [Phase 1 -- Rust scaffolding](#3-phase-1----rust-scaffolding)
4. [Phase 2 -- iOS implementation](#4-phase-2----ios-implementation)
5. [Phase 3 -- Android implementation](#5-phase-3----android-implementation)
6. [Phase 4 -- TypeScript layer](#6-phase-4----typescript-layer)
7. [Phase 5 -- Example app and testing](#7-phase-5----example-app-and-testing)
8. [File inventory](#8-file-inventory)
9. [Open questions](#9-open-questions)

---

## 1. Design decisions

### Keep our state machine, not theirs

The reference crate uses a flat `NativeAudioState` with raw status
strings (`"idle"`, `"playing"`, `"ended"`, `"error"`, `"loading"`) and
separate `isPlaying`/`buffering` booleans. It has no Ready or Paused
status -- both collapse into `"idle"`.

Our plugin has a 7-state `PlaybackStatus` enum (Idle, Loading, Ready,
Playing, Paused, Ended, Error) with explicit transition rules in
`transitions.rs` that gate which actions are valid. The TypeScript layer
enforces this at compile time via `Player<S>` discriminated unions.

**Decision**: Rewrite the native state machines (Swift/Kotlin) to match
our `transitions.rs` rules. The native implementations must produce
`PlayerState`-compatible JSON, not `NativeAudioState`.

### Hybrid desktop/mobile architecture

The reference crate is mobile-only with zero Rust audio logic. Our
plugin already has a working Rodio-based desktop player.

**Decision**: Use `#[cfg(mobile)]` / `#[cfg(desktop)]` to conditionally
wire up either native mobile plugins or the Rodio player. Desktop
behaviour is unchanged. The `is_native` command returns `true` on mobile.

### Commands stay in Rust on desktop, go native on mobile

On desktop, `#[command]` functions delegate to `RodioAudioPlayer`. On
mobile, the Rust commands are not reached -- Tauri routes them directly
to the native Swift/Kotlin `@Command`/`@objc` handlers.

**Decision**: The Rust `commands.rs` file stays as-is. The native
implementations handle the same command names and return the same JSON
shapes.

### Add features the reference crate lacks

The reference crate has no volume, mute, or loop support. Our plugin
needs all three on mobile.

**Decision**: Implement `set_volume`, `set_muted`, `set_loop` in the
native Swift/Kotlin code. Use `AVPlayer.volume` on iOS and
`ExoPlayer.volume` on Android for volume/mute. Use
`AVPlayerLooper`/`Player.REPEAT_MODE_ONE` for looping.

---

## 2. Shortcomings of the reference crate

These are issues in `tauri-plugin-native-audio` that this plan
explicitly avoids or fixes.

### State model

| Issue | Impact | Fix |
|-------|--------|-----|
| No Ready or Paused status | Can't distinguish "loaded but never played" from "nothing loaded" or "was playing, now paused" | Implement all 7 statuses from our `PlaybackStatus` enum |
| Raw status strings | Typo = silent runtime bug, no compile-time safety | Use Swift/Kotlin enums that map to our status names |
| `isPlaying` + `buffering` booleans alongside `status` | Redundant, can contradict each other | Single `status` field is authoritative; remove redundant booleans |
| No action gating | Any command callable in any state, invalid calls silently ignored or cause undefined behaviour | Validate transitions in native code matching `transitions.rs` rules |

### Missing features

| Feature | Status in reference | Our requirement |
|---------|-------------------|-----------------|
| Volume control | Not implemented | `set_volume(0.0..1.0)` |
| Mute/unmute | Not implemented | `set_muted(bool)` |
| Loop playback | Not implemented | `set_loop(bool)` |
| Stop (unload) | Not implemented (only `dispose` which tears down the whole player) | `stop()` resets to Idle, preserves settings |
| Seek validation | Accepts any position, no clamping to duration | Clamp to `0..duration` matching our `transitions::seek` |

### Architecture

| Issue | Impact | Fix |
|-------|--------|-----|
| Singleton `PlaybackRuntimeActor.shared` (iOS) / `NativeAudioRuntime` object (Android) | Can't have independent player instances; complicates testing | Accept this for now -- mobile apps typically have one audio player. Revisit if multi-instance becomes a requirement |
| `CheckpointStore` / progress persistence | Domain-specific to their app ("Stority"), not a general audio plugin concern | Do not adopt. Drop entirely |
| `SourceResolver` with `asset://` handling and file header sniffing | Useful for Tauri's asset protocol, but we already handle source loading in Rust (`load_source_data`) | Adopt the `asset://` URL normalisation logic. Drop file header sniffing -- AVPlayer/ExoPlayer handle format detection natively |
| `NowPlayingController` hardcodes `"Stority"` as fallback title | Leaks their app name into the lock screen | Use app display name or empty string as fallback |
| Android: all runtime logic in one 500-line `NativeAudioPlugin.kt` | Hard to navigate and test | Split into separate files: `AudioPlugin.kt`, `AudioRuntime.kt`, `AudioService.kt` |
| `onMain` synchronous dispatch in non-actor Swift classes | Potential deadlock if called from main thread callback that re-enters | Use `@MainActor` annotations or async dispatch where possible |
| Android `PendingSeekState` uses wall-clock timeout (1.5s) to expire stale seeks | Fragile on slow devices or large seeks | Use ExoPlayer's `onPositionDiscontinuity` callback with seek reason to definitively resolve seeks |
| No `stop` command -- only `dispose` which releases the player entirely | `dispose` tears down ExoPlayer/AVPlayer, requiring full reinitialisation | Implement `stop()` that resets state to Idle without destroying the player |

### Event model

| Issue | Impact | Fix |
|-------|--------|-----|
| Single event type (`native_audio_state`) for everything | High-frequency progress ticks carry the full state payload | Use two events matching our existing model: `state-changed` (transitions) and `time-update` (lightweight progress ticks) |
| iOS emits at 40 Hz in foreground | Excessive for a state event; wastes CPU/battery | Emit time-update at ~4 Hz (250ms) matching our Rodio monitor. The native player polls internally at higher rates but only emits at throttled intervals |

---

## 3. Phase 1 -- Rust scaffolding

### 3.1 Update `build.rs`

Add native project paths to the plugin builder:

```rust
tauri_plugin::Builder::new(COMMANDS)
   .android_path("android")
   .ios_path("ios")
   .build();
```

Ensure `COMMANDS` lists all command names (must match native handler
names exactly): `load`, `play`, `pause`, `stop`, `seek`, `set_volume`,
`set_muted`, `set_playback_rate`, `set_loop`, `get_state`, `is_native`.

### 3.2 Update `src/lib.rs`

Add conditional mobile plugin registration in `setup()`:

```rust
#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_audio);

pub fn init<R: Runtime>() -> TauriPlugin<R> {
   Builder::new("audio")
      .invoke_handler(tauri::generate_handler![...])
      .setup(|app_handle, _api| {
         #[cfg(target_os = "android")]
         _api.register_android_plugin(
            "com.silvermine.tauri_plugin_audio", "AudioPlugin"
         )?;

         #[cfg(target_os = "ios")]
         _api.register_ios_plugin(init_plugin_audio)?;

         #[cfg(desktop)]
         {
            // Existing Rodio player setup (unchanged)
         }

         Ok(())
      })
      .build()
}
```

### 3.3 Update `is_native` command

Return `true` on mobile targets:

```rust
#[command]
pub(crate) async fn is_native<R: Runtime>(_app: AppHandle<R>) -> Result<bool> {
   Ok(cfg!(mobile))
}
```

### 3.4 Update `Cargo.toml`

Gate desktop-only dependencies behind a `desktop` cfg:

```toml
[target.'cfg(not(any(target_os = "ios", target_os = "android")))'.dependencies]
audio-player = { path = "crates/audio-player" }
```

The `audio-player` crate (Rodio, symphonia, ureq) is only compiled for
desktop targets. Mobile targets only need `tauri` and `serde`.

---

## 4. Phase 2 -- iOS implementation

### 4.1 Directory structure

```
ios/
   Package.swift
   Sources/
      Plugin/
         AudioPlugin.swift            # Tauri Plugin subclass
      Player/
         AVPlayerAdapter.swift        # AVPlayer wrapper with KVO observers
      State/
         PlaybackStateMachine.swift   # State transitions matching transitions.rs
         PlayerStateSnapshot.swift    # PlayerState-compatible Encodable struct
      OS/
         AudioSessionController.swift # AVAudioSession configuration
         NowPlayingController.swift   # MPNowPlayingInfoCenter
         RemoteCommandController.swift# MPRemoteCommandCenter
```

### 4.2 `Package.swift`

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
   name: "tauri-plugin-audio",
   platforms: [.iOS(.v14)],
   products: [
      .library(name: "tauri-plugin-audio", type: .static,
               targets: ["tauri-plugin-audio"])
   ],
   dependencies: [
      .package(name: "Tauri", path: "../.tauri/tauri-api")
   ],
   targets: [
      .target(name: "tauri-plugin-audio",
              dependencies: [.byName(name: "Tauri")],
              path: "Sources")
   ]
)
```

### 4.3 `AudioPlugin.swift`

Subclass `Plugin`. Each `@objc public func` receives an `Invoke`,
parses args, dispatches to a coordinator actor, and resolves/rejects.

Commands to implement:

| Command | Invoke arg type | Response type |
|---------|----------------|---------------|
| `load` | `{ src: String, metadata?: AudioMetadata }` | `AudioActionResponse` |
| `play` | none | `AudioActionResponse` |
| `pause` | none | `AudioActionResponse` |
| `stop` | none | `AudioActionResponse` |
| `seek` | `{ position: Double }` | `AudioActionResponse` |
| `set_volume` | `{ level: Double }` | `PlayerState` |
| `set_muted` | `{ muted: Bool }` | `PlayerState` |
| `set_playback_rate` | `{ rate: Double }` | `PlayerState` |
| `set_loop` | `{ looping: Bool }` | `PlayerState` |
| `get_state` | none | `PlayerState` |
| `is_native` | none | `true` |

Export the plugin entry point:

```swift
@_cdecl("init_plugin_audio")
func initPlugin() -> Plugin {
   AudioPlugin()
}
```

Emit events via:
- `trigger("state-changed", data: playerState)` for state transitions
- `trigger("time-update", data: timeUpdate)` for progress ticks

### 4.4 `PlaybackStateMachine.swift`

Port `transitions.rs` to Swift. This is the **most critical file** --
it must enforce identical rules.

```swift
enum PlaybackStatus: String, Encodable {
   case idle, loading, ready, playing, paused, ended, error
}
```

Transition functions:

```swift
mutating func beginLoad(src: String, metadata: AudioMetadata) throws
mutating func load(src: String, metadata: AudioMetadata, duration: Double) throws
mutating func play() throws
mutating func pause() throws
mutating func stop() throws
mutating func seek(position: Double) throws
mutating func setVolume(level: Double) throws
mutating func setMuted(_ muted: Bool)
mutating func setPlaybackRate(_ rate: Double) throws
mutating func setLoop(_ looping: Bool)
mutating func error(_ message: String)
```

Each transport function validates the current status and throws
`InvalidStateError` for disallowed transitions, matching the Rust
`match` arms exactly.

**Seek revision fencing**: Add `sourceRevision: Int64` and
`seekRevision: Int64` fields plus a `PendingSeek` struct. This is
necessary because `AVPlayer.seek(to:)` is async -- stale callbacks from
superseded seeks must be discarded. The Rodio player doesn't need this
(seeks are synchronous), but AVPlayer does.

### 4.5 `PlayerStateSnapshot.swift`

An `Encodable` struct matching `PlayerState` JSON shape exactly:

```swift
struct PlayerStateSnapshot: Encodable {
   let status: PlaybackStatus
   let src: String?
   let title: String?
   let artist: String?
   let artwork: String?
   let currentTime: Double
   let duration: Double
   let volume: Double
   let muted: Bool
   let playbackRate: Double
   let loop: Bool        // Note: "loop" in JSON, not "looping"
   let error: String?
}
```

`AudioActionResponse` wrapper:

```swift
struct AudioActionResponse: Encodable {
   let player: PlayerStateSnapshot
   let expectedStatus: PlaybackStatus
   let isExpectedStatus: Bool
}
```

### 4.6 `AVPlayerAdapter.swift`

Adopt the reference crate's `PlayerAdapter.swift` with modifications:

**Keep from reference:**
- `AVPlayer` lifecycle management (`ensurePlayer`, `dispose`)
- KVO observers on `timeControlStatus`, `AVPlayerItem.status`,
  `AVPlayerItem.duration`
- `NotificationCenter` observers for `didPlayToEndTime` and
  `failedToPlayToEndTime`
- Periodic time observer for progress ticks
- `sourceRevision` tracking on all events to discard stale callbacks
- `seek(to:sourceRevision:seekRevision:)` with completion handler

**Modify:**
- Reduce periodic time observer interval from 40 Hz to 4 Hz (250ms)
  to match our existing tick rate
- Add `setVolume(_ volume: Float)` -- calls `player?.volume = volume`
- Add `setRate(_ rate: Float)` that works in both playing and paused
  states (reference only applies rate while playing)

**Drop:**
- No need for the reference's `onMain` synchronous dispatch pattern in
  the adapter. Use `@MainActor` isolation where possible to avoid
  deadlock risk

### 4.7 `AudioSessionController.swift`

Adopt from reference with minimal changes:

**Keep:**
- `AVAudioSession.setCategory(.playback)` configuration
- `setActive(true/false)` with `beginReceivingRemoteControlEvents`
- Interruption handling (began/ended with `shouldResume`)
- Route change handling (`oldDeviceUnavailable` = headphone disconnect)

**Modify:**
- Map interruption/route events to our state machine transitions:
  - Interruption began: `pause()` transition
  - Interruption ended (shouldResume): `play()` transition
  - Old device unavailable: `pause()` transition

### 4.8 `NowPlayingController.swift`

Adopt from reference with modifications:

**Keep:**
- `MPNowPlayingInfoCenter` updates (title, artist, duration, elapsed
  time, playback rate, artwork)
- Async artwork fetching with UUID-based cancellation

**Modify:**
- Use app display name as fallback instead of hardcoded `"Stority"`
- Add `playbackRate` from our `PlayerState` (reference has `rate`)

**Drop:**
- Nothing -- this is well-implemented in the reference

### 4.9 `RemoteCommandController.swift`

Adopt from reference as-is (well-structured):

**Keep:**
- `MPRemoteCommandCenter` registration for play, pause, toggle,
  changePlaybackPosition, skipForward, skipBackward
- Event-based dispatch via `RemoteCommandEvent` enum
- Cleanup via `unregister()`

**Future enhancement (not in initial scope):**
- Make skip interval configurable (currently hardcoded to 10s)

---

## 5. Phase 3 -- Android implementation

### 5.1 Directory structure

```
android/
   build.gradle.kts
   settings.gradle
   proguard-rules.pro
   consumer-rules.pro
   src/main/
      AndroidManifest.xml
      java/com/silvermine/tauri_plugin_audio/
         AudioPlugin.kt          # @TauriPlugin entry point
         AudioRuntime.kt         # ExoPlayer + MediaSession + state machine
         AudioService.kt         # MediaSessionService for foreground notification
         PlaybackState.kt        # State machine matching transitions.rs
         Models.kt               # PlayerState, AudioActionResponse, arg classes
```

### 5.2 `build.gradle.kts`

```kotlin
plugins {
   id("com.android.library")
   id("org.jetbrains.kotlin.android")
}

android {
   namespace = "com.silvermine.tauri_plugin_audio"
   compileSdk = 34
   defaultConfig { minSdk = 26 }
   compileOptions {
      sourceCompatibility = JavaVersion.VERSION_1_8
      targetCompatibility = JavaVersion.VERSION_1_8
   }
   kotlinOptions { jvmTarget = "1.8" }
}

dependencies {
   implementation("androidx.core:core-ktx:1.12.0")
   implementation("androidx.media3:media3-exoplayer:1.4.1")
   implementation("androidx.media3:media3-session:1.4.1")
   implementation("androidx.media3:media3-ui:1.4.1")
   implementation(project(":tauri-android"))
}
```

### 5.3 `AndroidManifest.xml`

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
   <uses-permission android:name="android.permission.INTERNET" />
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
   <uses-permission android:name="android.permission.WAKE_LOCK" />

   <application>
      <service
         android:name="com.silvermine.tauri_plugin_audio.AudioService"
         android:enabled="true"
         android:exported="false"
         android:foregroundServiceType="mediaPlayback">
         <intent-filter>
            <action android:name="androidx.media3.session.MediaSessionService" />
         </intent-filter>
      </service>
   </application>
</manifest>
```

### 5.4 `PlaybackState.kt`

Port `transitions.rs` to Kotlin:

```kotlin
enum class PlaybackStatus(val value: String) {
   Idle("idle"), Loading("loading"), Ready("ready"),
   Playing("playing"), Paused("paused"), Ended("ended"),
   Error("error")
}
```

Mutable state class with transition methods that throw
`IllegalStateException` for invalid transitions, mirroring the Rust
`Error::InvalidState` returns.

### 5.5 `AudioRuntime.kt`

Extract from the reference's inline `NativeAudioRuntime` object with
these changes:

**Keep from reference:**
- `ExoPlayer` lifecycle (`ensure`, `dispose`)
- `AudioAttributes` with `USAGE_MEDIA` + `AUDIO_CONTENT_TYPE_MUSIC`
- `setHandleAudioBecomingNoisy(true)` (auto-pause on headphone
  disconnect)
- `setWakeMode(C.WAKE_MODE_LOCAL)` for background playback
- `MediaSession` creation with `ForwardingPlayer` for seek
  back/forward commands
- `Player.Listener` for state changes, position discontinuity, errors
- Foreground/background adaptive tick rate

**Modify:**
- Use our `PlaybackState` class for state management instead of raw
  status strings
- Return `PlayerState`-compatible `JSObject` (with `volume`, `muted`,
  `loop` fields)
- Add `setVolume(volume: Float)` via `exoPlayer.volume = volume`
- Add `setMuted(muted: Boolean)` via `exoPlayer.volume = 0f` /
  restore
- Add `setLoop(looping: Boolean)` via
  `exoPlayer.repeatMode = if (looping) REPEAT_MODE_ONE else REPEAT_MODE_OFF`
- Implement `stop()` that resets to Idle without releasing the player
  (`exoPlayer.stop()` + `exoPlayer.clearMediaItems()`)
- Emit two event types: `state-changed` and `time-update`
- Resolve pending seeks via `onPositionDiscontinuity` callback reason
  instead of wall-clock timeout

**Drop:**
- `CheckpointStore` / progress persistence (domain-specific)
- `storyId` tracking

### 5.6 `AudioService.kt`

Adopt from reference's `NativeAudioService.kt`:

**Keep:**
- `MediaSessionService` with `PlayerNotificationManager`
- Foreground service management (start/stop)
- Notification channel creation
- `MediaDescriptionAdapter` for title, artist, artwork
- `NotificationListener` for foreground/background transitions

**Modify:**
- Use our package name (`com.silvermine.tauri_plugin_audio`)
- Use app display name as fallback (not hardcoded)

### 5.7 `AudioPlugin.kt`

**Keep from reference:**
- `@TauriPlugin` annotation
- `@Command` methods that parse `@InvokeArg` args and delegate to runtime
- `companion object` with `activeInstance` for event emission
- Notification permission request on `initialize`
- `activity.runOnUiThread` for `trigger()` calls

**Modify:**
- Implement all 11 commands matching our API (not their 12-command API)
- Return `PlayerState` / `AudioActionResponse` shaped `JSObject`s
- Split into separate file from `AudioRuntime`

---

## 6. Phase 4 -- TypeScript layer

### 6.1 No changes needed to `actions.ts`

The `PluginEventManager` class already handles dual event transport:

```typescript
const isNative = await invoke<boolean>('plugin:audio|is_native');
if (isNative) {
   // Uses addPluginListener('audio', eventName, handler)
} else {
   // Uses listen(tauriEventName, handler)
}
```

The `is_native` command returns `true` on mobile, switching to the
native plugin event channel automatically.

### 6.2 No changes needed to `types.ts` or `index.ts`

The native implementations return the same JSON shapes (`PlayerState`,
`AudioActionResponse`, `TimeUpdate`) as the Rust/Rodio implementation,
so the TypeScript types work without modification.

### 6.3 Verify event names match

Native iOS/Android must emit events with these exact names:
- `state-changed` (for `addPluginListener('audio', 'state-changed', ...)`)
- `time-update` (for `addPluginListener('audio', 'time-update', ...)`)

---

## 7. Phase 5 -- Example app and testing

### 7.1 Update example app

The example app at `examples/tauri-app/` already has Android and iOS
scaffolding (`gen/android/`, `gen/apple/`). Updates needed:

- Add `tauri-plugin-audio` to `src-tauri/capabilities/default.json`
  permissions for all new commands
- Test on iOS Simulator and Android Emulator
- Verify lock screen controls, headphone controls, notification shade

### 7.2 Test matrix

| Scenario | Desktop | iOS | Android |
|----------|---------|-----|---------|
| Load from URL | Rodio | AVPlayer | ExoPlayer |
| Load from file | Rodio | AVPlayer | ExoPlayer |
| Play / Pause / Stop | Rodio | AVPlayer | ExoPlayer |
| Seek (clamped) | Rodio | AVPlayer | ExoPlayer |
| Volume / Mute | Rodio sink | AVPlayer.volume | ExoPlayer.volume |
| Playback rate | Rodio sink | AVPlayer.rate | ExoPlayer.setPlaybackSpeed |
| Loop | Rodio re-append | AVPlayer re-seek or AVPlayerLooper | ExoPlayer.REPEAT_MODE_ONE |
| State events | Tauri emit | addPluginListener | trigger() |
| Time updates | Tauri emit | addPluginListener | trigger() |
| Lock screen controls | N/A | MPRemoteCommandCenter | MediaSession |
| Now Playing metadata | N/A | MPNowPlayingInfoCenter | MediaMetadata |
| Headphone disconnect | N/A | AVAudioSession route change | AudioBecomingNoisy |
| Audio interruption | N/A | AVAudioSession interruption | AudioFocus |
| Background playback | N/A | AVAudioSession .playback | Foreground service |
| Invalid state transitions | Error returned | Error returned | Error returned |

### 7.3 Parity tests

Write a shared test script (or manual test checklist) that exercises
the state machine through every valid and invalid transition on each
platform. The goal is to verify that native platforms reject the same
transitions that `transitions.rs` rejects.

---

## 8. File inventory

### New files

| File | Purpose |
|------|---------|
| `ios/Package.swift` | Swift Package Manager manifest |
| `ios/Sources/Plugin/AudioPlugin.swift` | iOS Tauri plugin entry point |
| `ios/Sources/Player/AVPlayerAdapter.swift` | AVPlayer wrapper |
| `ios/Sources/State/PlaybackStateMachine.swift` | State transitions (port of `transitions.rs`) |
| `ios/Sources/State/PlayerStateSnapshot.swift` | Encodable `PlayerState` / `AudioActionResponse` |
| `ios/Sources/OS/AudioSessionController.swift` | AVAudioSession management |
| `ios/Sources/OS/NowPlayingController.swift` | Lock screen Now Playing |
| `ios/Sources/OS/RemoteCommandController.swift` | Lock screen + headphone controls |
| `android/build.gradle.kts` | Android library build config |
| `android/settings.gradle` | Gradle settings |
| `android/proguard-rules.pro` | ProGuard rules |
| `android/consumer-rules.pro` | Consumer ProGuard rules |
| `android/src/main/AndroidManifest.xml` | Permissions + service declaration |
| `android/src/main/java/.../AudioPlugin.kt` | Android Tauri plugin entry point |
| `android/src/main/java/.../AudioRuntime.kt` | ExoPlayer + MediaSession coordinator |
| `android/src/main/java/.../AudioService.kt` | Foreground MediaSessionService |
| `android/src/main/java/.../PlaybackState.kt` | State transitions (port of `transitions.rs`) |
| `android/src/main/java/.../Models.kt` | Arg classes, state types |

### Modified files

| File | Change |
|------|--------|
| `build.rs` | Add `.android_path("android").ios_path("ios")` |
| `src/lib.rs` | Add `#[cfg(mobile)]` plugin registration, `#[cfg(desktop)]` Rodio setup |
| `src/commands.rs` | Change `is_native` to return `cfg!(mobile)` |
| `Cargo.toml` | Gate `audio-player` dependency behind `cfg(desktop)` |

### Unchanged files

| File | Reason |
|------|--------|
| `crates/audio-player/*` | Desktop-only, no changes needed |
| `guest-js/*` | Already supports native event transport via `is_native` |

---

## 9. Open questions

1. **Looping on iOS**: Use `AVPlayerLooper` (requires
   `AVQueuePlayer`) or manually seek to 0 on `didPlayToEndTime`? The
   latter is simpler and matches the Rodio approach (re-append source).
   `AVPlayerLooper` provides gapless looping but adds complexity.

2. **Source loading on mobile**: The Rodio player loads audio in Rust
   via `load_source_data()` (HTTP fetch or file read). On mobile,
   `AVPlayer`/`ExoPlayer` handle URLs natively. Should mobile `load()`
   pass the URL directly to the native player, or should Rust fetch
   the data and pass bytes? Direct URL is simpler and leverages native
   streaming/buffering. Recommendation: pass URL directly.

3. **SSRF protection on mobile**: The Rust layer has `reject_private_host()`
   to block requests to private IPs. If mobile players handle URLs
   natively, this check is bypassed. Should we validate the URL in
   Rust before passing it to native, or accept that mobile platforms
   have their own network security policies?

4. **Singleton vs per-handle player**: The reference uses a singleton.
   Our desktop player is created per `AppHandle`. For mobile, a
   singleton is pragmatic (one audio output, one media session, one
   Now Playing entry). Confirm this is acceptable.

5. **`asset://` URL scheme**: Tauri uses `asset://localhost/...` on
   mobile to reference bundled files. The native player needs to
   resolve these to file paths. Adopt the reference's
   `SourceResolver` normalisation logic for this, or use Tauri's
   built-in asset resolution APIs?

6. **Notification icon (Android)**: The reference looks for a drawable
   named `ic_notification`. Should we document this requirement, or
   fall back to a default icon without requiring app-specific
   configuration?
