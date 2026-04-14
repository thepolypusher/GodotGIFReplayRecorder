# GIF Replay Recorder

Continuously buffers gameplay in the background. Press F11 at any time to open an overlay where you can trim and export a replay as a GIF. The buffer duration is configurable (default 20 seconds). Works in the editor and in exported builds.

Inspired by Noita's built-in GIF recorder.

## Installation

1. Copy the `addons/replay_recorder/` folder into your project's `addons/` directory.
2. Enable the plugin: Project > Project Settings > Plugins > Replay GIF Recorder.
3. Run your game and press F11.

## How It Works

### Frame Buffering

While the game runs, the recorder captures the viewport at a configurable interval (default 20fps). Each frame is:

1. Grabbed from the viewport as an Image
2. Downscaled to the buffer resolution (default 640px wide, height derived from viewport aspect ratio)
3. Compressed with Zstd and stored in a rolling buffer

Zstd compression is used instead of PNG because both compress and decompress are native C++ implementations, keeping the per-frame capture cost low. The buffer keeps a configurable duration of gameplay (default 20 seconds). When frames are older than the buffer duration, they are evicted. Call `estimate_buffer_size_mb()` to preview the memory cost for a given duration, resolution, and frame rate.

Player settings (enabled, capture FPS, buffer duration) are saved to `user://replay_recorder.cfg` and persist between sessions.

### GIF Encoding

When the player clicks Save GIF, encoding runs on a background thread:

1. **Frame preparation** -- Zstd-compressed frames are decompressed back to Images, optionally resized to the chosen export resolution, and the watermark (if configured) is composited onto each frame.

2. **Color quantization** -- A 256-color palette is built using median-cut quantization. Colors are sampled from a representative subset of frames (~100K pixel samples), then the RGB color space is recursively split into 256 boxes along whichever channel has the widest range (with perceptual bias toward green). Each box's average becomes a palette entry.

3. **Palette indexing** -- A 32x32x32 RGB lookup table (32K entries, 5 bits per channel) maps every pixel to its nearest palette index in O(1). This avoids the O(256) linear scan per pixel that would otherwise dominate encoding time.

4. **LZW compression** -- Each frame's indexed pixels are compressed using a trie-based LZW encoder, producing the GIF89a image data stream. The trie dictionary resets at 4096 codes per the GIF spec.

5. **Output** -- The final binary includes a GIF89a header, global color table, Netscape looping extension (infinite loop), optional comment extension (metadata), and the compressed frame data.

The entire encoder is pure GDScript with no native dependencies.

### Watermark and Metadata

Developers can configure an image watermark that is alpha-blended onto every exported frame. The watermark is scaled to fill the export resolution and rendered at a configurable opacity (default 5%).

A metadata template string is embedded in the GIF as a Comment Extension. Built-in variables include `{project_name}`, `{timestamp}`, `{resolution}`, `{duration}`, `{fps}`, and `{frames}`. Custom variables can be registered from game code:

```gdscript
# In your game's _ready():
ReplayRecorder.set_metadata_var("version", "1.2.3")
```

Then use `{version}` in the metadata template project setting.

## Developer Settings

Configure under Project > Project Settings > addons/replay_recorder/:

| Setting | Default | Description |
|---|---|---|
| `export_directory` | `user://replays` | Where GIF files are saved |
| `ui_layer` | `2000` | CanvasLayer order for the overlay. Set higher than your game's highest UI layer |
| `toggle_action` | `replay_recorder_toggle` | Input action name. If undefined in Input Map, defaults to F11 |
| `buffer_resolution` | `640` | Capture width in pixels. Height derived from viewport aspect ratio. Requires restart |
| `default_buffer_duration` | `20` | How many seconds of gameplay to keep in the buffer. Players can change at runtime (10s–60s) |
| `max_buffer_duration` | `60` | Upper bound for the player-facing buffer duration slider |
| `enabled_in_release` | `true` | Whether the recorder runs in exported builds |
| `watermark_image` | (empty) | Path to a PNG/image overlaid on exported frames |
| `watermark_opacity` | `0.05` | Watermark alpha (0.01 = barely visible, 1.0 = opaque) |
| `metadata_template` | `{project_name} \| {timestamp} \| {resolution}` | GIF comment metadata. Leave empty to omit |

## Exposing Settings to Players

The recorder's player-facing settings can be wired into your game's options menu. Buffer duration controls how many seconds of gameplay are available for replay, and `estimate_buffer_size_mb()` lets you show the memory cost alongside a slider:

```gdscript
# Setting up a duration slider:
slider.min_value = 10.0
slider.max_value = ReplayRecorder.get_max_buffer_duration()
slider.value = ReplayRecorder.buffer_duration

# Showing estimated memory cost:
label.text = "~%.1f MB" % ReplayRecorder.estimate_buffer_size_mb(slider.value)

# When the player changes the slider:
func _on_duration_slider_changed(value: float) -> void:
    ReplayRecorder.update_buffer_duration(value)
    label.text = "~%.1f MB" % ReplayRecorder.estimate_buffer_size_mb(value)
```

`estimate_buffer_size_mb()` uses the actual observed compression ratio once frames exist in the buffer. Before any frames are captured, it falls back to a conservative heuristic. You can also pass explicit parameters to estimate for a different configuration:

```gdscript
# Estimate for a specific duration, resolution, and frame rate:
var mb := ReplayRecorder.estimate_buffer_size_mb(30.0, 640, 360, 20)
```

Capture FPS and enabled state can also be updated at runtime:

```gdscript
ReplayRecorder.update_capture_fps(15)
ReplayRecorder.update_enabled(false)
```

All player settings are automatically saved to `user://replay_recorder.cfg`.

## Player Controls

| Input | Action |
|---|---|
| F11 (or configured action) | Open/close the recorder |
| Left-click timeline | Set clip start |
| Right-click timeline | Set clip end |
| Arrow keys | Browse frames |
| Enter | Save GIF |
| ESC | Close |

## Platform Support

- Windows, macOS, Linux
- Not available on Web or headless builds
- Can be disabled in release builds via the `enabled_in_release` setting

## License

MIT License. See [LICENSE](LICENSE).
