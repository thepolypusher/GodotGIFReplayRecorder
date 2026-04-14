extends Node
## Replay Recorder — Autoload
##
## Continuously captures gameplay frames into a rolling buffer.
## Press the configured toggle action (default F11) to open the recorder UI
## for trimming and exporting clips as GIFs.
##
## Developer settings: Project > Project Settings > addons/replay_recorder/
## Player settings: stored in user://replay_recorder.cfg

const PLAYER_SETTINGS_PATH := "user://replay_recorder.cfg"
const UI_SCENE_PATH := "res://addons/replay_recorder/replay_recorder_ui.tscn"

# --- Developer settings (from Project Settings, read once in _ready) ---
var _export_directory: String
var _ui_layer: int
var _toggle_action: String
var _buffer_width: int
var _buffer_height: int
var _default_buffer_duration: float
var _max_buffer_duration: float
var _enabled_in_release: bool
var _watermark_image_path: String
var _watermark_opacity: float
var _metadata_template: String

# --- Watermark & metadata ---
var _watermark_source: Image = null # Loaded once from developer's image path
var _metadata_vars: Dictionary = {} # Custom variables for metadata template

# --- Player settings (from ConfigFile, can change at runtime) ---
var enabled: bool = true:
	set(value):
		enabled = value
		set_process(enabled and _can_run)
var buffer_duration: float = 20.0
var capture_fps: int = 20

# --- Rolling buffer ---
# { "data": PackedByteArray (zstd-compressed RGBA8), "timestamp": float, "index": int }
var _frame_buffer: Array[Dictionary] = []
var _current_memory_usage: int = 0
var _frame_index: int = 0
var _capture_interval: float = 1.0 / 20.0
var _time_accumulator: float = 0.0

# --- UI state ---
var _ui_instance: Node = null
var _is_ui_open: bool = false
var _was_already_paused: bool = false
var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE

# --- Internal ---
var _can_run: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Check platform/build restrictions
	if OS.get_name() == "Web" or DisplayServer.get_name() == "headless":
		_can_run = false
		set_process(false)
		set_process_input(false)
		return

	_load_developer_settings()

	if not OS.is_debug_build() and not _enabled_in_release:
		_can_run = false
		set_process(false)
		set_process_input(false)
		return

	_register_default_input_action()
	_load_player_settings()

	_capture_interval = 1.0 / capture_fps
	_can_run = true
	set_process(enabled)

	print("[GIFReplayRecorder] Ready — %dx%d @ %dfps, buffer %.0fs (~%.1fMB), toggle: %s" % [
		_buffer_width, _buffer_height, capture_fps,
		buffer_duration, estimate_buffer_size_mb(), _toggle_action
	])


func _process(delta: float) -> void:
	if _is_ui_open:
		return

	_time_accumulator += delta
	if _time_accumulator >= _capture_interval:
		_time_accumulator = 0.0
		_capture_frame()


func _unhandled_input(event: InputEvent) -> void:
	if not _can_run:
		return
	if event.is_action_pressed(_toggle_action):
		get_viewport().set_input_as_handled()
		if _is_ui_open:
			close_ui()
		else:
			open_ui()


# =============================================================================
# Public API
# =============================================================================


func open_ui() -> void:
	if _is_ui_open:
		return
	if _frame_buffer.is_empty():
		print("[GIFReplayRecorder] No frames buffered yet.")
		return

	_was_already_paused = get_tree().paused
	_previous_mouse_mode = Input.mouse_mode
	get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_is_ui_open = true

	if _ui_instance == null:
		var ui_scene := load(UI_SCENE_PATH) as PackedScene
		assert(ui_scene != null, "[GIFReplayRecorder] Failed to load UI scene at %s" % UI_SCENE_PATH)
		_ui_instance = ui_scene.instantiate()
	add_child(_ui_instance) # _ready() runs here, assigns @onready vars
	_ui_instance.setup(self)


func close_ui() -> void:
	if not _is_ui_open:
		return
	_is_ui_open = false

	if _ui_instance != null and _ui_instance.is_inside_tree():
		remove_child(_ui_instance)

	Input.set_mouse_mode(_previous_mouse_mode)

	if not _was_already_paused:
		get_tree().paused = false


func get_frame_count() -> int:
	return _frame_buffer.size()


func get_frame_image(buffer_index: int) -> Image:
	assert(
		buffer_index >= 0 and buffer_index < _frame_buffer.size(),
		"[GIFReplayRecorder] buffer_index %d out of range (0..%d)" % [
			buffer_index, _frame_buffer.size() - 1,
		]
	)
	var entry: Dictionary = _frame_buffer[buffer_index]
	var raw: PackedByteArray = entry.data.decompress(entry.raw_size, FileAccess.COMPRESSION_ZSTD)
	return Image.create_from_data(_buffer_width, _buffer_height, false, Image.FORMAT_RGBA8, raw)


func get_frame_compressed_data(buffer_index: int) -> Dictionary:
	return _frame_buffer[buffer_index]


func get_frame_timestamp(buffer_index: int) -> float:
	return _frame_buffer[buffer_index].timestamp


func get_buffer_duration_seconds() -> float:
	if _frame_buffer.size() < 2:
		return 0.0
	return _frame_buffer.back().timestamp - _frame_buffer.front().timestamp


func get_export_directory() -> String:
	var dir_path: String = ProjectSettings.get_setting(
		"addons/replay_recorder/export_directory", "user://replays"
	)
	var global_path := ProjectSettings.globalize_path(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
	return global_path


func get_max_buffer_duration() -> float:
	return _max_buffer_duration


func get_buffer_width() -> int:
	return _buffer_width


func get_buffer_height() -> int:
	return _buffer_height


func get_ui_layer() -> int:
	return _ui_layer


func update_capture_fps(new_fps: int) -> void:
	capture_fps = clampi(new_fps, 5, 20)
	_capture_interval = 1.0 / capture_fps
	save_player_settings()


func update_buffer_duration(new_seconds: float) -> void:
	buffer_duration = clampf(new_seconds, 10.0, _max_buffer_duration)
	_evict_over_time_limit()
	save_player_settings()


## Estimate the memory usage in megabytes for a given buffer configuration.
## Uses the actual observed compression ratio when frames exist in the buffer,
## otherwise falls back to a conservative heuristic (~4:1 zstd compression).
## Pass -1 for any parameter to use the current setting.
func estimate_buffer_size_mb(
	duration_seconds: float = -1.0,
	width: int = -1,
	height: int = -1,
	fps: int = -1,
) -> float:
	if duration_seconds < 0.0:
		duration_seconds = buffer_duration
	if width < 0:
		width = _buffer_width
	if height < 0:
		height = _buffer_height
	if fps < 0:
		fps = capture_fps

	var total_frames := ceili(duration_seconds * fps)
	var avg_frame_bytes: float

	if _frame_buffer.size() > 0 and _current_memory_usage > 0:
		# Scale observed average by resolution ratio
		var observed_avg := float(_current_memory_usage) / _frame_buffer.size()
		var observed_pixels := _buffer_width * _buffer_height
		var target_pixels := width * height
		avg_frame_bytes = observed_avg * float(target_pixels) / float(observed_pixels)
	else:
		# Conservative heuristic: RGBA8 raw size with ~4:1 zstd compression
		avg_frame_bytes = float(width * height * 4) / 4.0

	return (total_frames * avg_frame_bytes) / (1024.0 * 1024.0)


func get_current_memory_usage_mb() -> float:
	return _current_memory_usage / (1024.0 * 1024.0)


func update_enabled(new_enabled: bool) -> void:
	enabled = new_enabled
	if not enabled:
		_frame_buffer.clear()
		_current_memory_usage = 0
	save_player_settings()


## Register a custom variable for the metadata template.
## Call this from your game code (e.g., in _ready):
##   ReplayRecorder.set_metadata_var("version", GameManager.BUILD_VERSION)
## Then use {version} in the metadata_template project setting.
func set_metadata_var(key: String, value: String) -> void:
	_metadata_vars[key] = value


## Build a watermark Image sized for the given export dimensions.
## Returns null if no watermark is configured.
func get_watermark_for_export(export_width: int, export_height: int) -> Image:
	if _watermark_source == null:
		return null
	var wm := _watermark_source.duplicate() as Image
	wm.resize(export_width, export_height, Image.INTERPOLATE_BILINEAR)
	if wm.get_format() != Image.FORMAT_RGBA8:
		wm.convert(Image.FORMAT_RGBA8)
	# Apply developer opacity to the watermark's alpha channel
	for y in wm.get_height():
		for x in wm.get_width():
			var color := wm.get_pixel(x, y)
			color.a *= _watermark_opacity
			wm.set_pixel(x, y, color)
	return wm


## Build the metadata string from the template, substituting all variables.
func get_metadata_string(
		export_width: int, export_height: int,
		duration: float, fps: int, frame_count: int,
) -> String:
	if _metadata_template == "":
		return ""
	var result := _metadata_template
	# Built-in variables
	result = result.replace(
		"{project_name}",
		ProjectSettings.get_setting("application/config/name", ""),
	)
	result = result.replace("{timestamp}", Time.get_datetime_string_from_system())
	result = result.replace("{resolution}", "%dx%d" % [export_width, export_height])
	result = result.replace("{duration}", "%.1fs" % duration)
	result = result.replace("{fps}", str(fps))
	result = result.replace("{frames}", str(frame_count))
	# Custom variables
	for key: String in _metadata_vars:
		result = result.replace("{%s}" % key, _metadata_vars[key])
	return result


# =============================================================================
# Frame Capture
# =============================================================================


func _capture_frame() -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return
	image.resize(_buffer_width, _buffer_height, Image.INTERPOLATE_BILINEAR)
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var raw_data := image.get_data()
	var compressed := raw_data.compress(FileAccess.COMPRESSION_ZSTD)

	var entry := {
		"data": compressed,
		"raw_size": raw_data.size(),
		"timestamp": Time.get_ticks_msec() / 1000.0,
		"index": _frame_index,
	}
	_frame_index += 1
	_frame_buffer.append(entry)
	_current_memory_usage += compressed.size()
	_evict_over_time_limit()


func _evict_over_time_limit() -> void:
	if _frame_buffer.size() < 2:
		return
	var latest_time: float = _frame_buffer.back().timestamp
	var cutoff := latest_time - buffer_duration
	while _frame_buffer.size() > 1 and _frame_buffer[0].timestamp < cutoff:
		var evicted: Dictionary = _frame_buffer.pop_front()
		_current_memory_usage -= evicted.data.size()


# =============================================================================
# Settings
# =============================================================================


func _load_developer_settings() -> void:
	_export_directory = ProjectSettings.get_setting(
		"addons/replay_recorder/export_directory", "user://replays"
	)
	_ui_layer = ProjectSettings.get_setting(
		"addons/replay_recorder/ui_layer", 2000
	)
	_toggle_action = ProjectSettings.get_setting(
		"addons/replay_recorder/toggle_action", "replay_recorder_toggle"
	)
	var buf_width: int = ProjectSettings.get_setting(
		"addons/replay_recorder/buffer_resolution", 640
	)
	_default_buffer_duration = ProjectSettings.get_setting(
		"addons/replay_recorder/default_buffer_duration", 20.0
	)
	_max_buffer_duration = ProjectSettings.get_setting(
		"addons/replay_recorder/max_buffer_duration", 60.0
	)
	buffer_duration = _default_buffer_duration
	_enabled_in_release = ProjectSettings.get_setting(
		"addons/replay_recorder/enabled_in_release", true
	)
	_watermark_image_path = ProjectSettings.get_setting(
		"addons/replay_recorder/watermark_image", ""
	)
	_watermark_opacity = ProjectSettings.get_setting(
		"addons/replay_recorder/watermark_opacity", 0.05
	)
	_metadata_template = ProjectSettings.get_setting(
		"addons/replay_recorder/metadata_template", "{project_name} | {timestamp} | {resolution}"
	)

	# Load watermark image if configured
	if _watermark_image_path != "" and ResourceLoader.exists(_watermark_image_path):
		var tex := load(_watermark_image_path)
		if tex is Texture2D:
			_watermark_source = tex.get_image()
		elif tex is Image:
			_watermark_source = tex

	# Derive buffer height from viewport aspect ratio
	var viewport_size := get_viewport().get_visible_rect().size
	_buffer_width = buf_width
	if viewport_size.y > 0:
		var aspect_ratio := viewport_size.x / viewport_size.y
		_buffer_height = int(buf_width / aspect_ratio)
	else:
		_buffer_height = int(buf_width * 9.0 / 16.0) # Fallback to 16:9
	# Ensure even dimensions for compatibility
	if _buffer_height % 2 != 0:
		_buffer_height += 1


func _load_player_settings() -> void:
	var config := ConfigFile.new()
	if config.load(PLAYER_SETTINGS_PATH) != OK:
		return
	enabled = config.get_value("recorder", "enabled", true)
	buffer_duration = clampf(
		config.get_value("recorder", "buffer_duration", _default_buffer_duration),
		10.0, _max_buffer_duration
	)
	capture_fps = config.get_value("recorder", "capture_fps", 20)


func save_player_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("recorder", "enabled", enabled)
	config.set_value("recorder", "buffer_duration", buffer_duration)
	config.set_value("recorder", "capture_fps", capture_fps)
	config.save(PLAYER_SETTINGS_PATH)


func _register_default_input_action() -> void:
	if InputMap.has_action(_toggle_action):
		return
	InputMap.add_action(_toggle_action)
	var key_event := InputEventKey.new()
	key_event.keycode = KEY_F11
	InputMap.action_add_event(_toggle_action, key_event)


func _exit_tree() -> void:
	# Clean up UI and any encoding thread
	if _ui_instance != null:
		if _ui_instance.has_method("force_cancel_encoding"):
			_ui_instance.force_cancel_encoding()
		if _ui_instance.is_inside_tree():
			remove_child(_ui_instance)
		_ui_instance.queue_free()
		_ui_instance = null
