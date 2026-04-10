@tool
extends EditorPlugin

const AUTOLOAD_NAME := "ReplayRecorder"
const AUTOLOAD_PATH := "res://addons/replay_recorder/replay_recorder.gd"

## Project Settings — Developer Configuration
##
## These settings appear under Project > Project Settings > addons/replay_recorder/.
## Godot does not support tooltips on custom plugin settings (only built-in engine
## settings get descriptions from compiled XML docs).
##
## export_directory ........ Where GIF files are saved. Use user:// paths for portability.
## ui_layer ................ CanvasLayer order for the recorder overlay. Set higher than
##                           your game's highest UI layer (including custom cursors).
## toggle_action ........... Input action name to open/close the recorder. If the action
##                           doesn't exist in Input Map, a default F11 binding is added
##                           at runtime. Override by defining the action in Input Map.
## buffer_resolution ....... Capture width in pixels (height derived from viewport aspect
##                           ratio). Higher = better GIF quality but fewer seconds of
##                           buffer per MB. Requires restart.
## default_memory_budget_mb  Starting memory budget for frame buffer. Players can change
##                           this at runtime. At 640px, expect ~200-350KB per frame, so
##                           150MB ~ 25-40 seconds at 20fps.
## max_export_seconds ...... Maximum clip duration players can export. Prevents accidental
##                           multi-minute GIF exports.
## enabled_in_release ...... Whether the recorder runs in exported/release builds. Set
##                           false if you only want it available during development.
## watermark_image ......... Path to a PNG/image overlaid on every exported frame. Leave
##                           empty for no watermark. The image is scaled to fill the
##                           export resolution and alpha-blended at watermark_opacity.
## watermark_opacity ....... Opacity for the watermark overlay (0.01 = barely visible,
##                           1.0 = fully opaque). Default 0.05 (5%).
## metadata_template ....... Template string embedded as a GIF comment. Supports variables:
##                           {project_name}, {timestamp}, {resolution}, {duration}, {fps},
##                           {frames}, plus custom vars registered via set_metadata_var().
##                           Leave empty to omit metadata. Example:
##                           "{project_name} v{version} | {timestamp} | {resolution}"
const SETTINGS := {
	"addons/replay_recorder/export_directory": {
		"value": "user://replays",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_DIR,
		"hint_string": "",
	},
	"addons/replay_recorder/ui_layer": {
		"value": 2000,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "1,4096,1",
	},
	"addons/replay_recorder/toggle_action": {
		"value": "replay_recorder_toggle",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	},
	"addons/replay_recorder/buffer_resolution": {
		"value": 640,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "240,960,1",
	},
	"addons/replay_recorder/default_memory_budget_mb": {
		"value": 150,
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "10,500,10",
	},
	"addons/replay_recorder/max_export_seconds": {
		"value": 30.0,
		"type": TYPE_FLOAT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "5,60,1",
	},
	"addons/replay_recorder/enabled_in_release": {
		"value": true,
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	},
	"addons/replay_recorder/watermark_image": {
		"value": "",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_FILE,
		"hint_string": "*.png,*.jpg,*.jpeg,*.webp,*.svg",
	},
	"addons/replay_recorder/watermark_opacity": {
		"value": 0.05,
		"type": TYPE_FLOAT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "0.01,1.0,0.01",
	},
	"addons/replay_recorder/metadata_template": {
		"value": "{project_name} | {timestamp} | {resolution}",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "",
	},
}


func _enter_tree() -> void:
	_register_settings()
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
	_remove_settings()


func _remove_settings() -> void:
	for path: String in SETTINGS:
		if ProjectSettings.has_setting(path):
			ProjectSettings.set_setting(path, null)


func _register_settings() -> void:
	for path: String in SETTINGS:
		var info: Dictionary = SETTINGS[path]
		if not ProjectSettings.has_setting(path):
			ProjectSettings.set_setting(path, info.value)
		ProjectSettings.set_initial_value(path, info.value)
		ProjectSettings.add_property_info({
			"name": path,
			"type": info.type,
			"hint": info.hint,
			"hint_string": info.hint_string,
		})
	ProjectSettings.set_restart_if_changed("addons/replay_recorder/buffer_resolution", true)
