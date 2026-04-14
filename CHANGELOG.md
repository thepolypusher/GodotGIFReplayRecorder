# Changelog

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
