extends CanvasLayer
## Replay Recorder UI
##
## Full-screen overlay for trimming and exporting replay clips as GIFs.
## Opened/closed by ReplayRecorder autoload.

# --- References ---
var _recorder: Node # ReplayRecorder autoload

# --- Buffer snapshot ---
var _buffer_size: int = 0

# --- Timeline ---
const THUMBNAIL_COUNT := 40
var _thumbnail_textures: Array[ImageTexture] = []
var _thumbnail_buffer_indices: Array[int] = []
var _trim_start: int = 0
var _trim_end: int = 0 # Inclusive
var _hovered_index: int = -1

# --- Preview ---
var _preview_texture: ImageTexture
var _preview_playing: bool = true
var _preview_frame: int = 0
var _preview_timer: float = 0.0

# --- Export ---
var _export_width: int = 480
var _export_height: int = 270
var _export_fps: int = 20
var _size_options: Array[String] = []
var _fps_options: Array[String] = []
var _size_selected_index: int = 0
var _fps_selected_index: int = 0
var _open_dropdown_overlay: Control = null

# --- Encoding ---
var _encoding_thread: Thread = null
var _encoding_mutex: Mutex = Mutex.new()
var _encoding_progress: float = 0.0
var _cancel_requested: bool = false
var _encoding_done: bool = false
var _encoding_output_path: String = ""
var _spinner_angle: float = 0.0

# --- Real-time tracking (immune to Engine.time_scale = 0) ---
var _last_process_msec: int = 0

# --- Node references (assigned in _ready) ---
@onready var _background: ColorRect = %Background
@onready var _title_label: Label = %TitleLabel
@onready var _buffer_info_label: Label = %BufferInfoLabel
@onready var _close_button: Button = %CloseButton
@onready var _preview_center: CenterContainer = %PreviewCenter
@onready var _preview_rect: TextureRect = %PreviewRect
@onready var _timeline_bar: Control = %TimelineBar
@onready var _start_time_label: Label = %StartTimeLabel
@onready var _duration_label: Label = %DurationLabel
@onready var _end_time_label: Label = %EndTimeLabel
@onready var _reset_trim_button: Button = %ResetTrimButton
@onready var _size_dropdown: Button = %SizeDropdown
@onready var _fps_dropdown: Button = %FPSDropdown
@onready var _export_info_label: Label = %ExportInfoLabel
@onready var _open_folder_button: Button = %OpenFolderButton
@onready var _save_button: Button = %SaveButton
@onready var _progress_container: VBoxContainer = %ProgressContainer
@onready var _progress_label: Label = %ProgressLabel
@onready var _progress_bar: ProgressBar = %ProgressBar
@onready var _spinner: Control = %Spinner
@onready var _cancel_button: Button = %CancelButton
@onready var _hint_label: Label = %HintLabel
@onready var _controls_container: HBoxContainer = %ControlsContainer
@onready var _action_container: HBoxContainer = %ActionContainer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_progress_container.visible = false

	# Connect signals
	_close_button.pressed.connect(_on_close_pressed)
	_reset_trim_button.pressed.connect(_on_reset_trim_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_open_folder_button.pressed.connect(_on_open_folder_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	_size_dropdown.pressed.connect(_on_size_dropdown_pressed)
	_fps_dropdown.pressed.connect(_on_fps_dropdown_pressed)

	_timeline_bar.draw.connect(_on_timeline_draw)
	_timeline_bar.gui_input.connect(_on_timeline_input)
	_timeline_bar.mouse_exited.connect(_on_timeline_mouse_exited)
	_spinner.draw.connect(_on_spinner_draw)
	_preview_center.resized.connect(_update_preview_size)

	# Setup reusable preview texture
	_preview_texture = ImageTexture.new()
	_preview_rect.texture = _preview_texture


func setup(recorder: Node) -> void:
	_recorder = recorder
	layer = recorder.get_ui_layer()
	_buffer_size = recorder.get_frame_count()
	_trim_start = 0
	_trim_end = _buffer_size - 1
	_hovered_index = -1
	_preview_frame = _trim_start
	_preview_playing = true
	_preview_timer = 0.0

	_export_width = recorder.get_buffer_width()
	_export_height = recorder.get_buffer_height()
	_export_fps = 20

	_setup_size_dropdown()
	_setup_fps_dropdown()
	_generate_thumbnails()
	_update_time_labels()
	_update_export_info()
	_update_buffer_info()
	_update_preview(_trim_start)
	_update_preview_size()
	_set_encoding_ui(false)

	_last_process_msec = Time.get_ticks_msec()
	_save_button.grab_focus.call_deferred()


func _process(_delta: float) -> void:
	# Use real time so the UI works even when Engine.time_scale = 0 (game paused)
	var now_msec := Time.get_ticks_msec()
	var real_delta := (now_msec - _last_process_msec) / 1000.0 if _last_process_msec > 0 else 0.0
	_last_process_msec = now_msec

	# Poll encoding progress
	if _encoding_thread != null:
		_encoding_mutex.lock()
		var progress := _encoding_progress
		var done := _encoding_done
		_encoding_mutex.unlock()

		_progress_bar.value = progress * 100.0
		if progress < 0.2:
			_progress_label.text = "Preparing frames... %d%%" % int(progress * 100.0)
		else:
			_progress_label.text = "Encoding... %d%%" % int(progress * 100.0)

		# Animate spinner
		_spinner_angle += real_delta * TAU # One full rotation per second
		_spinner.queue_redraw()

		if done:
			_encoding_thread.wait_to_finish()
			_encoding_thread = null
			_on_encoding_complete()
		return

	# Preview playback
	if _preview_playing and _buffer_size > 0 and _hovered_index < 0:
		_preview_timer += real_delta
		var frame_duration := 1.0 / _export_fps
		if _preview_timer >= frame_duration:
			_preview_timer = 0.0
			_preview_frame += 1
			if _preview_frame > _trim_end:
				_preview_frame = _trim_start
			_update_preview(_preview_frame)


func _unhandled_input(event: InputEvent) -> void:
	if _encoding_thread != null:
		# Block all input during encoding except cancel
		get_viewport().set_input_as_handled()
		if event.is_action_pressed("ui_cancel"):
			_on_cancel_pressed()
		return

	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _open_dropdown_overlay != null:
			_close_dropdown_popup()
		else:
			_on_close_pressed()
	elif event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_on_save_pressed()
	elif event.is_action_pressed("ui_left"):
		get_viewport().set_input_as_handled()
		_navigate_timeline(-1)
	elif event.is_action_pressed("ui_right"):
		get_viewport().set_input_as_handled()
		_navigate_timeline(1)


# =============================================================================
# Timeline
# =============================================================================


func _generate_thumbnails() -> void:
	_thumbnail_textures.clear()
	_thumbnail_buffer_indices.clear()

	if _buffer_size == 0:
		return

	var count := mini(THUMBNAIL_COUNT, _buffer_size)
	for i in count:
		var buffer_idx := int(float(i) / (count - 1) * (_buffer_size - 1)) if count > 1 else 0
		_thumbnail_buffer_indices.append(buffer_idx)
		var img: Image = _recorder.get_frame_image(buffer_idx)
		# Tiny thumbnails for timeline
		img.resize(48, int(48.0 / _export_width * _export_height), Image.INTERPOLATE_NEAREST)
		var tex := ImageTexture.create_from_image(img)
		_thumbnail_textures.append(tex)

	_timeline_bar.queue_redraw()


func _on_timeline_draw() -> void:
	if _thumbnail_textures.is_empty():
		return

	var bar_size := _timeline_bar.size
	var thumb_count := _thumbnail_textures.size()
	var thumb_w := bar_size.x / thumb_count
	var thumb_h := bar_size.y

	# Draw thumbnails
	for i in thumb_count:
		var rect := Rect2(i * thumb_w, 0, thumb_w, thumb_h)
		_timeline_bar.draw_texture_rect(_thumbnail_textures[i], rect, false)

		# Dim unselected regions
		var buffer_idx := _thumbnail_buffer_indices[i]
		if buffer_idx < _trim_start or buffer_idx > _trim_end:
			_timeline_bar.draw_rect(rect, Color(0, 0, 0, 0.6))

	# Selection overlay borders
	var start_x := _buffer_index_to_timeline_x(_trim_start)
	var end_x := _buffer_index_to_timeline_x(_trim_end) + thumb_w

	# Start marker (green)
	_timeline_bar.draw_line(
		Vector2(start_x, 0), Vector2(start_x, thumb_h),
		Color.GREEN, 2.0
	)
	# End marker (red)
	_timeline_bar.draw_line(
		Vector2(end_x, 0), Vector2(end_x, thumb_h),
		Color.RED, 2.0
	)

	# Hover indicator (white)
	if _hovered_index >= 0 and _hovered_index < thumb_count:
		var hover_x := _hovered_index * thumb_w
		_timeline_bar.draw_rect(
			Rect2(hover_x, 0, thumb_w, thumb_h),
			Color(1, 1, 1, 0.3)
		)

	# Playback position (white line)
	if _preview_frame >= 0:
		var play_x := _buffer_index_to_timeline_x(_preview_frame) + thumb_w * 0.5
		_timeline_bar.draw_line(
			Vector2(play_x, 0), Vector2(play_x, thumb_h),
			Color.WHITE, 1.0
		)


func _on_timeline_input(event: InputEvent) -> void:
	if not event is InputEventMouse:
		return

	var bar_size := _timeline_bar.size
	var thumb_count := _thumbnail_textures.size()
	if thumb_count == 0:
		return

	var thumb_w := bar_size.x / thumb_count
	var hover_idx := clampi(int(event.position.x / thumb_w), 0, thumb_count - 1)
	var buffer_idx := _thumbnail_buffer_indices[hover_idx]

	if event is InputEventMouseMotion:
		_hovered_index = hover_idx
		_update_preview(buffer_idx)
		_timeline_bar.queue_redraw()

	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			# Set start — clamp to not exceed end
			if buffer_idx <= _trim_end:
				_trim_start = buffer_idx
				_preview_frame = _trim_start
				_update_time_labels()
				_update_export_info()
				_timeline_bar.queue_redraw()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# Set end — clamp to not go below start
			if buffer_idx >= _trim_start:
				_trim_end = buffer_idx
				_update_time_labels()
				_update_export_info()
				_timeline_bar.queue_redraw()


func _on_timeline_mouse_exited() -> void:
	_hovered_index = -1
	_timeline_bar.queue_redraw()


func _buffer_index_to_timeline_x(buffer_idx: int) -> float:
	if _thumbnail_buffer_indices.is_empty():
		return 0.0
	var bar_width := _timeline_bar.size.x
	var thumb_count := _thumbnail_buffer_indices.size()
	var thumb_w := bar_width / thumb_count

	# Find which thumbnail slot this buffer index maps to
	var best_slot := 0
	for i in thumb_count:
		if _thumbnail_buffer_indices[i] <= buffer_idx:
			best_slot = i
	return best_slot * thumb_w


func _navigate_timeline(direction: int) -> void:
	_preview_frame = clampi(_preview_frame + direction, 0, _buffer_size - 1)
	_update_preview(_preview_frame)
	_timeline_bar.queue_redraw()


func _on_spinner_draw() -> void:
	var center := _spinner.size / 2.0
	var radius := mini(int(_spinner.size.x), int(_spinner.size.y)) / 2.0 - 2.0
	var arc_length := TAU * 0.75 # 270-degree arc
	_spinner.draw_arc(
		center, radius, _spinner_angle, _spinner_angle + arc_length,
		24, Color.WHITE, 2.5, true,
	)


# =============================================================================
# Preview
# =============================================================================


func _update_preview(buffer_index: int) -> void:
	if buffer_index < 0 or buffer_index >= _buffer_size:
		return
	var img: Image = _recorder.get_frame_image(buffer_index)
	_preview_texture.set_image(img)


func _update_preview_size() -> void:
	if _recorder == null:
		return
	var available := _preview_center.size
	if available.x <= 0 or available.y <= 0:
		return

	var buf_w: int = _recorder.get_buffer_width()
	var buf_h: int = _recorder.get_buffer_height()
	var aspect := float(buf_w) / buf_h

	if _export_width >= buf_w:
		# Largest resolution: scale to fill available space
		var fit_w := int(available.x)
		var fit_h := int(fit_w / aspect)
		if fit_h > int(available.y):
			fit_h = int(available.y)
			fit_w = int(fit_h * aspect)
		_preview_rect.custom_minimum_size = Vector2(fit_w, fit_h)
	else:
		# Smaller export sizes: show at actual resolution
		_preview_rect.custom_minimum_size = Vector2(
			_export_width, _export_height,
		)


# =============================================================================
# Export Controls
# =============================================================================


func _setup_size_dropdown() -> void:
	_size_options.clear()
	var buf_w: int = _recorder.get_buffer_width()
	var buf_h: int = _recorder.get_buffer_height()
	var aspect := float(buf_w) / buf_h

	# Presets from largest to smallest (640 is the social media sweet spot)
	var widths := [640, buf_w, 320, 240]
	# Remove duplicates if buffer width matches a preset
	var seen := {}
	for w in widths:
		if w in seen:
			continue
		seen[w] = true
		var h := int(w / aspect)
		if h % 2 != 0:
			h += 1
		_size_options.append("%dx%d" % [w, h])

	# Default to buffer resolution (second entry, or first if buf_w == 640)
	_size_selected_index = 0 if buf_w == 640 else 1
	_size_dropdown.text = _size_options[_size_selected_index]
	_export_width = buf_w
	_export_height = buf_h


func _setup_fps_dropdown() -> void:
	_fps_options = ["20", "15", "10"]
	_fps_selected_index = 0
	_fps_dropdown.text = _fps_options[_fps_selected_index]
	_export_fps = 20


func _on_size_selected(index: int) -> void:
	_size_selected_index = index
	var text := _size_options[index]
	_size_dropdown.text = text
	var parts := text.split("x")
	_export_width = int(parts[0])
	_export_height = int(parts[1])
	_update_export_info()
	_update_preview_size()


func _on_fps_selected(index: int) -> void:
	_fps_selected_index = index
	var text := _fps_options[index]
	_fps_dropdown.text = text
	_export_fps = int(text)
	_update_export_info()


func _on_size_dropdown_pressed() -> void:
	# Toggle: if open, close (any open click was already swallowed by the overlay)
	if _open_dropdown_overlay != null:
		_close_dropdown_popup()
		return
	_show_dropdown_popup(_size_dropdown, _size_options, _on_size_selected)


func _on_fps_dropdown_pressed() -> void:
	if _open_dropdown_overlay != null:
		_close_dropdown_popup()
		return
	_show_dropdown_popup(_fps_dropdown, _fps_options, _on_fps_selected)


# Built without OptionButton.get_popup() because that popup is a Window subclass
# and renders independently of the parent CanvasLayer's z-order — when the addon
# runs at a high layer, the popup ends up behind the rest of the recorder UI and
# behind game UI on lower layers. A Control-based popup in the same CanvasLayer
# inherits the correct draw order.
func _show_dropdown_popup(button: Button, items: Array[String], on_select: Callable) -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_open_dropdown_overlay = overlay

	var panel := PanelContainer.new()
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.15, 0.15, 0.15, 0.98)
	panel_style.set_content_margin_all(4)
	panel.add_theme_stylebox_override("panel", panel_style)
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	panel.add_child(vbox)

	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Color(0.3, 0.3, 0.5)
	hover_style.set_content_margin_all(4)
	var transparent_style := StyleBoxEmpty.new()
	transparent_style.set_content_margin_all(4)

	for i in items.size():
		var item := Button.new()
		item.text = items[i]
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.custom_minimum_size = Vector2(button.size.x, 0)
		item.add_theme_stylebox_override("normal", transparent_style)
		item.add_theme_stylebox_override("hover", hover_style)
		item.add_theme_stylebox_override("pressed", hover_style)
		item.add_theme_stylebox_override("focus", transparent_style)
		item.add_theme_color_override("font_color", Color.WHITE)
		item.add_theme_color_override("font_hover_color", Color.WHITE)
		var idx := i
		item.pressed.connect(func() -> void:
			_close_dropdown_popup()
			on_select.call(idx)
		)
		vbox.add_child(item)

	overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			if not panel.get_global_rect().has_point(overlay.get_global_mouse_position()):
				_close_dropdown_popup()
	)

	# Position below the button, or above if it would overflow the viewport
	var button_rect := button.get_global_rect()
	var popup_size := panel.get_combined_minimum_size()
	var viewport_size := get_viewport().get_visible_rect().size
	var below_y := button_rect.position.y + button_rect.size.y
	if below_y + popup_size.y > viewport_size.y:
		panel.position = Vector2(button_rect.position.x, button_rect.position.y - popup_size.y)
	else:
		panel.position = Vector2(button_rect.position.x, below_y)


func _close_dropdown_popup() -> void:
	if _open_dropdown_overlay != null:
		_open_dropdown_overlay.queue_free()
		_open_dropdown_overlay = null


# =============================================================================
# Info Labels
# =============================================================================


func _update_time_labels() -> void:
	var start_time: float = _recorder.get_frame_timestamp(_trim_start)
	var end_time: float = _recorder.get_frame_timestamp(_trim_end)
	var base_time: float = _recorder.get_frame_timestamp(0)

	_start_time_label.text = "Start: %s" % _format_time(start_time - base_time)
	_end_time_label.text = "End: %s" % _format_time(end_time - base_time)
	_duration_label.text = "Duration: %s" % _format_time(end_time - start_time)


func _update_export_info() -> void:
	var frame_count := _trim_end - _trim_start + 1
	var duration := 0.0
	if frame_count > 1:
		duration = _recorder.get_frame_timestamp(_trim_end) - _recorder.get_frame_timestamp(_trim_start)
	_export_info_label.text = "%d frames, %s, %dx%d" % [
		frame_count, _format_time(duration), _export_width, _export_height
	]


func _update_buffer_info() -> void:
	var duration: float = _recorder.get_buffer_duration_seconds()
	var limit: float = _recorder.buffer_duration
	var mb: float = _recorder.get_current_memory_usage_mb()
	_buffer_info_label.text = "Buffer: %s / %s (~%.1fMB)" % [
		_format_time(duration), _format_time(limit), mb
	]


func _format_time(seconds: float) -> String:
	if seconds < 0:
		seconds = 0.0
	var mins := int(seconds) / 60
	var secs := fmod(seconds, 60.0)
	if mins > 0:
		return "%d:%04.1f" % [mins, secs]
	return "%.1fs" % secs


# =============================================================================
# Save / Encode
# =============================================================================


func _on_save_pressed() -> void:
	if _encoding_thread != null:
		return
	# Collect compressed frame data on main thread (fast — just reference copies)
	var frame_entries: Array[Dictionary] = []
	for i in range(_trim_start, _trim_end + 1):
		frame_entries.append(_recorder.get_frame_compressed_data(i))

	if frame_entries.is_empty():
		return

	# Prepare output path
	var export_dir: String = _recorder.get_export_directory()
	var project_name: String = ProjectSettings.get_setting("application/config/name", "replay")
	project_name = project_name.replace(" ", "").to_lower()
	var short_id := String.num_int64(Time.get_ticks_msec() % 1000000, 36)
	_encoding_output_path = export_dir + "/" + project_name + "_" + short_id + ".gif"

	# Start encoding
	_encoding_mutex.lock()
	_encoding_progress = 0.0
	_cancel_requested = false
	_encoding_done = false
	_encoding_mutex.unlock()

	_set_encoding_ui(true)

	# Prepare watermark and metadata on main thread (fast)
	var watermark: Image = _recorder.get_watermark_for_export(_export_width, _export_height)
	var clip_duration := 0.0
	if _trim_end > _trim_start:
		clip_duration = (
			_recorder.get_frame_timestamp(_trim_end)
			- _recorder.get_frame_timestamp(_trim_start)
		)
	var metadata: String = _recorder.get_metadata_string(
		_export_width, _export_height, clip_duration, _export_fps, frame_entries.size()
	)

	var buf_w: int = _recorder.get_buffer_width()
	var buf_h: int = _recorder.get_buffer_height()
	var needs_resize: bool = _export_width != buf_w
	_encoding_thread = Thread.new()
	_encoding_thread.start(
		_encode_thread_func.bind(
			frame_entries, buf_w, buf_h, _export_fps,
			_encoding_output_path, needs_resize, watermark, metadata,
		)
	)


func _encode_thread_func(
	frame_entries: Array[Dictionary], buf_w: int, buf_h: int,
	fps: int, output_path: String,
	needs_resize: bool, watermark: Image, metadata: String,
) -> void:
	# Decompress frames, resize, and apply watermark in the thread (0-20% progress)
	var frames: Array[Image] = []
	var wm_rect := Rect2i()
	if watermark != null:
		wm_rect = Rect2i(Vector2i.ZERO, watermark.get_size())

	for i in frame_entries.size():
		_encoding_mutex.lock()
		var cancelled := _cancel_requested
		_encoding_mutex.unlock()
		if cancelled:
			_encoding_mutex.lock()
			_encoding_done = true
			_encoding_mutex.unlock()
			return

		var entry: Dictionary = frame_entries[i]
		var raw: PackedByteArray = entry.data.decompress(entry.raw_size, FileAccess.COMPRESSION_ZSTD)
		var img := Image.create_from_data(buf_w, buf_h, false, Image.FORMAT_RGBA8, raw)
		if needs_resize:
			img.resize(_export_width, _export_height, Image.INTERPOLATE_BILINEAR)
		if watermark != null:
			img.blend_rect(watermark, wm_rect, Vector2i.ZERO)
		frames.append(img)

		_encoding_mutex.lock()
		_encoding_progress = 0.2 * (float(i + 1) / frame_entries.size())
		_encoding_mutex.unlock()

	# Encode GIF (20-100% progress)
	var progress_cb := func(p: float) -> void:
		_encoding_mutex.lock()
		_encoding_progress = 0.2 + 0.8 * p
		_encoding_mutex.unlock()

	var cancel_cb := func() -> bool:
		_encoding_mutex.lock()
		var cancelled := _cancel_requested
		_encoding_mutex.unlock()
		return cancelled

	var gif_bytes := GifEncoder.encode(frames, fps, progress_cb, cancel_cb, metadata)

	if not gif_bytes.is_empty():
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		if file != null:
			file.store_buffer(gif_bytes)
			file.close()
		else:
			push_error("[GIFReplayRecorder] Failed to write GIF to %s" % output_path)

	_encoding_mutex.lock()
	_encoding_done = true
	_encoding_mutex.unlock()


func _on_encoding_complete() -> void:
	_set_encoding_ui(false)

	# Check if it was cancelled
	_encoding_mutex.lock()
	var was_cancelled := _cancel_requested
	_encoding_mutex.unlock()

	if was_cancelled:
		# Delete partial file
		if FileAccess.file_exists(_encoding_output_path):
			DirAccess.remove_absolute(_encoding_output_path)
		_progress_label.text = "Cancelled"
	elif FileAccess.file_exists(_encoding_output_path):
		_export_info_label.text = "GIF saved!"
	else:
		_export_info_label.text = "Save failed — check export directory"


func _on_cancel_pressed() -> void:
	_encoding_mutex.lock()
	_cancel_requested = true
	_encoding_mutex.unlock()


func force_cancel_encoding() -> void:
	if _encoding_thread == null:
		return
	_encoding_mutex.lock()
	_cancel_requested = true
	_encoding_mutex.unlock()
	_encoding_thread.wait_to_finish()
	_encoding_thread = null

	if FileAccess.file_exists(_encoding_output_path):
		DirAccess.remove_absolute(_encoding_output_path)


func _set_encoding_ui(encoding: bool) -> void:
	_progress_container.visible = encoding
	_save_button.visible = not encoding
	_close_button.disabled = encoding
	_controls_container.visible = not encoding
	_action_container.visible = not encoding
	_reset_trim_button.disabled = encoding

	if encoding:
		_cancel_button.grab_focus.call_deferred()
	else:
		_save_button.grab_focus.call_deferred()


# =============================================================================
# Button Handlers
# =============================================================================


func _on_close_pressed() -> void:
	if _encoding_thread != null:
		return
	_recorder.close_ui()


func _on_reset_trim_pressed() -> void:
	_trim_start = 0
	_trim_end = _buffer_size - 1
	_preview_frame = _trim_start
	_update_time_labels()
	_update_export_info()
	_timeline_bar.queue_redraw()


func _on_open_folder_pressed() -> void:
	var dir_path: String = _recorder.get_export_directory()
	OS.shell_open(dir_path)
