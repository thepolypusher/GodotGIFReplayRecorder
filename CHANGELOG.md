# Changelog

## v1.2.0

### Added
- `capture_format` project setting (RGB8/RGBA8). RGB8 is the default and is sufficient for opaque games; RGBA8 preserves alpha for games with transparent backgrounds. Requires restart.

### Changed
- Resize and compression are offloaded to a worker thread, keeping the capture path off the main thread.
- The frame buffer is now a pre-allocated ring with O(1) eviction, replacing an array that shifted every element on each evict. Combined with RGB8 this reduces buffer memory by roughly 25%.
- Capture cadence runs on wall-clock time rather than the process delta. Above `Engine.time_scale = 1.0` the recorder previously captured well beyond `capture_fps`, inflating buffer memory and producing exports that played back in slow motion. Eviction was already real-time; both ends now agree. Capture remains suspended while `Engine.time_scale` is 0.

### Fixed
- Crash on reopening the recorder UI (`buffer_index N out of range`). The worker dequeued a frame before resizing and compressing it, so the drain performed on open saw an empty queue while a frame was still in flight. That frame's late push evicted from the front of the ring while the UI was building thumbnails against the frame count it had just snapshotted. The worker now dequeues only once a frame has landed in the ring.
- Frame accessors (`get_frame_image`, `get_frame_compressed_data`, `get_frame_timestamp`) now always release the buffer mutex and clamp a stale index rather than asserting. The previous assertion returned while still holding the mutex, deadlocking the worker on its next push; and since `assert()` is stripped from release builds, the same stale index there dereferenced an evicted slot.

## v1.1.2

### Fixed
- Asset Library downloads no longer include repository screenshots and icon. `.gitattributes` now uses a whitelist (`/**  export-ignore`, `/addons  !export-ignore`) so only the `addons/` folder is shipped, and normalizes text files to LF line endings.

## v1.1.1

### Fixed
- Size and FPS dropdowns rendered behind the dim background and other UI elements when the addon ran at a high `ui_layer`. The dropdowns now use a Control-based popup inside the same CanvasLayer instead of `OptionButton`'s `Window`-based popup, so they always draw on top.

### Changed
- Dropdown popups flip upward when they would overflow the bottom of the viewport.
- ESC dismisses an open dropdown popup before closing the recorder UI.

### Docs
- Added a **Programmatic Control** section covering persistent player-facing toggles (`update_enabled`, `update_buffer_duration`, `update_capture_fps`) and transient per-scene pause via the `enabled` property — with explicit guidance on which to use for options menus vs. main-menu/cutscene scenes.
- Top-level README synced with the addon README (the top-level was stale, still referencing the removed `default_memory_budget_mb` and `max_export_seconds` settings).

## v1.1.0

### Breaking changes
- Replaced the memory-budget model with a **buffer duration** model. The buffer now evicts frames older than a configured number of seconds instead of tracking raw bytes.
  - Project settings `default_memory_budget_mb` and `max_export_seconds` were removed.
  - New project settings: `default_buffer_duration` (default 20s) and `max_buffer_duration` (default 60s).
  - `user://replay_recorder.cfg` key `memory_budget_mb` → `buffer_duration`. Old configs fall back to defaults.
- Removed the max-export-duration cap. Players can now export any trimmed range.
- Renamed public API:
  - `update_memory_budget()` → `update_buffer_duration()`
  - `get_max_export_seconds()` → `get_max_buffer_duration()`
  - Property `memory_budget_bytes` → `buffer_duration`

### Added
- `estimate_buffer_size_mb(duration, width, height, fps)` — predicts memory cost using the observed compression ratio, with a conservative fallback before any frames exist.
- `get_current_memory_usage_mb()` for live memory readout.
- README section showing how to wire buffer duration / capture FPS / enabled state into a game's options menu.

### Changed
- Overlay UI uses real (wall-clock) time, so preview playback and the encoding spinner work correctly when the game is paused via `Engine.time_scale = 0`.
- Preview scales to fit the available space at the largest export resolution, and shows actual size for smaller ones.
- Buffer info label now shows `used / limit (~MB)` instead of `used / budget MB`.

## v1.0.0

Initial release.
