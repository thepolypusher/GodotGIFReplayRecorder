# Changelog

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
