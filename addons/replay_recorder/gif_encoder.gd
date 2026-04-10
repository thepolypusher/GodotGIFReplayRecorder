class_name GifEncoder
## Pure GDScript GIF89a encoder.
##
## Encodes an array of Images into a GIF byte stream with:
## - Median-cut color quantization (256 colors)
## - LZW compression with trie-based dictionary
## - Netscape looping extension
##
## Usage:
##   var gif_bytes := GifEncoder.encode(frames, 20)
##   FileAccess.open("output.gif", FileAccess.WRITE).store_buffer(gif_bytes)


## Encode frames to a GIF byte stream.
## [param frames]: Array of Images, all same size, RGBA8 format.
## [param fps]: Playback frame rate (converted to GIF centisecond delay).
## [param progress_callback]: Optional Callable(float) called with 0.0-1.0 progress.
## [param cancel_check]: Optional Callable() -> bool. If it returns true, encoding aborts
## and an empty PackedByteArray is returned.
## [param metadata]: Optional comment string embedded in the GIF as a Comment Extension.
static func encode(
	frames: Array[Image],
	fps: int,
	progress_callback: Callable = Callable(),
	cancel_check: Callable = Callable(),
	metadata: String = "",
) -> PackedByteArray:
	assert(frames.size() > 0, "[GIFReplayRecorder] No frames to encode")
	var width := frames[0].get_width()
	var height := frames[0].get_height()

	if progress_callback.is_valid():
		progress_callback.call(0.0)

	# Ensure all frames are RGBA8
	for frame in frames:
		if frame.get_format() != Image.FORMAT_RGBA8:
			frame.convert(Image.FORMAT_RGBA8)

	# Step 1: Quantize colors (0% - 40%)
	var quant := _quantize_frames(frames, progress_callback, cancel_check)
	if quant.is_empty():
		return PackedByteArray()

	var palette: PackedByteArray = quant.palette
	var indexed_frames: Array = quant.indexed_frames

	if progress_callback.is_valid():
		progress_callback.call(0.4)

	# Step 2: Build GIF binary
	var gif := PackedByteArray()

	# Header
	gif.append_array("GIF89a".to_ascii_buffer())

	# Logical Screen Descriptor
	_append_le16(gif, width)
	_append_le16(gif, height)
	# Packed: GCT flag=1, color_res=7 (8 bits), sort=0, GCT_size=7 (256 entries)
	gif.append(0xF7)
	gif.append(0) # Background color index
	gif.append(0) # Pixel aspect ratio

	# Global Color Table (256 * 3 = 768 bytes)
	gif.append_array(palette)

	# Netscape Application Extension (infinite loop)
	gif.append(0x21) # Extension introducer
	gif.append(0xFF) # Application extension label
	gif.append(0x0B) # Block size (11)
	gif.append_array("NETSCAPE2.0".to_ascii_buffer())
	gif.append(0x03) # Sub-block size
	gif.append(0x01) # Sub-block ID (loop)
	_append_le16(gif, 0) # Loop count (0 = infinite)
	gif.append(0x00) # Block terminator

	# Comment Extension (metadata)
	if metadata != "":
		gif.append(0x21) # Extension introducer
		gif.append(0xFE) # Comment label
		gif.append_array(_to_sub_blocks(metadata.to_utf8_buffer()))

	# Frame delay in centiseconds
	var delay_cs := maxi(2, roundi(100.0 / fps))

	# Step 3: Encode each frame (40% - 100%)
	for i in indexed_frames.size():
		if cancel_check.is_valid() and cancel_check.call():
			return PackedByteArray()

		# Graphics Control Extension
		gif.append(0x21) # Extension introducer
		gif.append(0xF9) # GCE label
		gif.append(0x04) # Block size
		gif.append(0x00) # Packed: disposal=0, no user input, no transparency
		_append_le16(gif, delay_cs)
		gif.append(0x00) # Transparent color index (unused)
		gif.append(0x00) # Block terminator

		# Image Descriptor
		gif.append(0x2C) # Image separator
		_append_le16(gif, 0) # Left
		_append_le16(gif, 0) # Top
		_append_le16(gif, width)
		_append_le16(gif, height)
		gif.append(0x00) # Packed: no local color table, not interlaced

		# LZW Image Data
		gif.append(8) # Minimum code size
		var lzw_data := _lzw_encode(indexed_frames[i])
		gif.append_array(_to_sub_blocks(lzw_data))

		if progress_callback.is_valid():
			progress_callback.call(0.4 + 0.6 * (float(i + 1) / indexed_frames.size()))

	# Trailer
	gif.append(0x3B)

	return gif


# =============================================================================
# Color Quantization — Median-Cut
# =============================================================================


static func _quantize_frames(
	frames: Array[Image],
	progress_callback: Callable,
	cancel_check: Callable,
) -> Dictionary:
	# Sample colors from a subset of frames (every 16th pixel, every 4th frame)
	# ~100K samples is more than sufficient for 256-color median-cut
	var colors := PackedInt32Array()
	var sample_step := 16
	var frame_step := maxi(1, frames.size() / 28)

	for fi in range(0, frames.size(), frame_step):
		var data := frames[fi].get_data()
		var pixel_count := data.size() / 4
		for px in range(0, pixel_count, sample_step):
			var offset := px * 4
			colors.append((data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2])

	if cancel_check.is_valid() and cancel_check.call():
		return {}

	# Median-cut: split color space into 256 boxes
	var boxes: Array[Dictionary] = [_make_box(colors)]

	while boxes.size() < 256:
		# Find box with largest range
		var best_idx := 0
		var best_range := 0
		for i in boxes.size():
			if boxes[i].range > best_range:
				best_range = boxes[i].range
				best_idx = i
		if best_range == 0:
			break
		var split := _split_box(boxes[best_idx])
		boxes[best_idx] = split[0]
		boxes.append(split[1])

	if progress_callback.is_valid():
		progress_callback.call(0.15)

	# Build palette from box averages
	var palette := PackedByteArray()
	palette.resize(768) # 256 * 3
	for i in boxes.size():
		var avg := _box_average(boxes[i])
		palette[i * 3] = avg[0]
		palette[i * 3 + 1] = avg[1]
		palette[i * 3 + 2] = avg[2]

	if cancel_check.is_valid() and cancel_check.call():
		return {}

	# Build 32x32x32 LUT for O(1) nearest-palette lookup (5-bit per channel)
	var lut := PackedByteArray()
	lut.resize(32768) # 32*32*32
	for ri in 32:
		for gi in 32:
			for bi in 32:
				lut[ri * 1024 + gi * 32 + bi] = _find_nearest_palette_index(
					palette, ri * 8 + 4, gi * 8 + 4, bi * 8 + 4
				)

	if cancel_check.is_valid() and cancel_check.call():
		return {}

	# Index all frames using LUT
	var indexed_frames: Array[PackedByteArray] = []

	for fi in frames.size():
		if cancel_check.is_valid() and cancel_check.call():
			return {}

		var data := frames[fi].get_data()
		var pixel_count := data.size() / 4
		var indexed := PackedByteArray()
		indexed.resize(pixel_count)

		for px in pixel_count:
			var offset := px * 4
			var ri: int = data[offset] >> 3
			var gi: int = data[offset + 1] >> 3
			var bi: int = data[offset + 2] >> 3
			indexed[px] = lut[ri * 1024 + gi * 32 + bi]

		indexed_frames.append(indexed)

		if progress_callback.is_valid():
			progress_callback.call(0.15 + 0.25 * (float(fi + 1) / frames.size()))

	return { "palette": palette, "indexed_frames": indexed_frames }


static func _make_box(colors: PackedInt32Array) -> Dictionary:
	# Colors are packed ints: (r << 16) | (g << 8) | b
	var r_min := 255; var r_max := 0
	var g_min := 255; var g_max := 0
	var b_min := 255; var b_max := 0

	for c in colors:
		var r := (c >> 16) & 0xFF
		var g := (c >> 8) & 0xFF
		var b := c & 0xFF
		if r < r_min: r_min = r
		if r > r_max: r_max = r
		if g < g_min: g_min = g
		if g > g_max: g_max = g
		if b < b_min: b_min = b
		if b > b_max: b_max = b

	var r_range := r_max - r_min
	var g_range := g_max - g_min
	var b_range := b_max - b_min

	# Bias green for perceptual quality
	var weighted_g := int(g_range * 1.2)
	var max_range: int
	var split_channel: int # 0=R (bits 16-23), 1=G (bits 8-15), 2=B (bits 0-7)

	if weighted_g >= r_range and weighted_g >= b_range:
		max_range = weighted_g
		split_channel = 1
	elif r_range >= b_range:
		max_range = r_range
		split_channel = 0
	else:
		max_range = b_range
		split_channel = 2

	return {
		"colors": colors,
		"range": max_range,
		"split_channel": split_channel,
	}


static func _split_box(box: Dictionary) -> Array[Dictionary]:
	var ch: int = box.split_channel
	var colors: PackedInt32Array = box.colors

	# Extract channel value for sorting
	var shift: int
	match ch:
		0: shift = 16 # R
		1: shift = 8  # G
		_: shift = 0  # B

	# Convert to Array for sort_custom, then split
	var color_array := Array(colors)
	color_array.sort_custom(func(a: int, b: int) -> bool:
		return ((a >> shift) & 0xFF) < ((b >> shift) & 0xFF)
	)

	var mid := color_array.size() / 2
	var left := PackedInt32Array(color_array.slice(0, mid))
	var right := PackedInt32Array(color_array.slice(mid))

	return [_make_box(left), _make_box(right)]


static func _box_average(box: Dictionary) -> PackedByteArray:
	var colors: PackedInt32Array = box.colors
	if colors.is_empty():
		var black := PackedByteArray()
		black.resize(3)
		return black

	var r_sum := 0; var g_sum := 0; var b_sum := 0
	for c in colors:
		r_sum += (c >> 16) & 0xFF
		g_sum += (c >> 8) & 0xFF
		b_sum += c & 0xFF

	var count := colors.size()
	var avg := PackedByteArray()
	avg.resize(3)
	avg[0] = r_sum / count
	avg[1] = g_sum / count
	avg[2] = b_sum / count
	return avg


static func _find_nearest_palette_index(palette: PackedByteArray, r: int, g: int, b: int) -> int:
	var best_dist := 999999
	var best_idx := 0
	var palette_size := palette.size() / 3

	for i in palette_size:
		var offset := i * 3
		var dr := r - palette[offset]
		var dg := g - palette[offset + 1]
		var db := b - palette[offset + 2]
		# Perceptual weighting (green-sensitive)
		var dist := dr * dr * 2 + dg * dg * 4 + db * db * 3
		if dist < best_dist:
			best_dist = dist
			best_idx = i
			if dist == 0:
				break
	return best_idx


# =============================================================================
# LZW Compression — Trie-based dictionary
# =============================================================================


static func _lzw_encode(indexed_pixels: PackedByteArray) -> PackedByteArray:
	var min_code_size := 8
	var clear_code := 1 << min_code_size # 256
	var eoi_code := clear_code + 1 # 257

	# Bit stream state — pre-allocated output with indexed writes
	var output := PackedByteArray()
	output.resize(maxi(1024, indexed_pixels.size()))
	var write_pos := 0
	var bit_buffer := 0
	var bit_count := 0
	var code_size := min_code_size + 1 # Starts at 9
	var next_code := eoi_code + 1 # Starts at 258

	# Build initial trie
	var root := {}
	for i in clear_code:
		root[i] = { "code": i }

	# Emit clear code
	bit_buffer |= (clear_code << bit_count)
	bit_count += code_size
	while bit_count >= 8:
		output[write_pos] = bit_buffer & 0xFF
		write_pos += 1
		bit_buffer >>= 8
		bit_count -= 8

	if indexed_pixels.is_empty():
		bit_buffer |= (eoi_code << bit_count)
		bit_count += code_size
		while bit_count >= 8:
			output[write_pos] = bit_buffer & 0xFF
			write_pos += 1
			bit_buffer >>= 8
			bit_count -= 8
		if bit_count > 0:
			output[write_pos] = bit_buffer & 0xFF
			write_pos += 1
		output.resize(write_pos)
		return output

	# Start with first pixel
	var current_node: Dictionary = root[indexed_pixels[0]]

	for i in range(1, indexed_pixels.size()):
		var pixel: int = indexed_pixels[i]

		if pixel in current_node:
			current_node = current_node[pixel]
		else:
			# Emit code for current sequence
			var code: int = current_node.code
			bit_buffer |= (code << bit_count)
			bit_count += code_size
			while bit_count >= 8:
				if write_pos >= output.size():
					output.resize(output.size() * 2)
				output[write_pos] = bit_buffer & 0xFF
				write_pos += 1
				bit_buffer >>= 8
				bit_count -= 8

			# Add new sequence to trie
			if next_code < 4096:
				current_node[pixel] = { "code": next_code }
				next_code += 1
				if next_code > (1 << code_size) and code_size < 12:
					code_size += 1
			else:
				# Table full — emit clear code and reset
				bit_buffer |= (clear_code << bit_count)
				bit_count += code_size
				while bit_count >= 8:
					if write_pos >= output.size():
						output.resize(output.size() * 2)
					output[write_pos] = bit_buffer & 0xFF
					write_pos += 1
					bit_buffer >>= 8
					bit_count -= 8
				root.clear()
				for j in clear_code:
					root[j] = { "code": j }
				next_code = eoi_code + 1
				code_size = min_code_size + 1

			current_node = root[pixel]

	# Emit final sequence code
	var final_code: int = current_node.code
	bit_buffer |= (final_code << bit_count)
	bit_count += code_size
	while bit_count >= 8:
		if write_pos >= output.size():
			output.resize(output.size() * 2)
		output[write_pos] = bit_buffer & 0xFF
		write_pos += 1
		bit_buffer >>= 8
		bit_count -= 8

	# Emit end-of-information
	bit_buffer |= (eoi_code << bit_count)
	bit_count += code_size
	while bit_count >= 8:
		if write_pos >= output.size():
			output.resize(output.size() * 2)
		output[write_pos] = bit_buffer & 0xFF
		write_pos += 1
		bit_buffer >>= 8
		bit_count -= 8

	# Flush remaining bits
	if bit_count > 0:
		if write_pos >= output.size():
			output.resize(output.size() * 2)
		output[write_pos] = bit_buffer & 0xFF
		write_pos += 1

	output.resize(write_pos)
	return output


# =============================================================================
# GIF Sub-Blocks
# =============================================================================


static func _to_sub_blocks(data: PackedByteArray) -> PackedByteArray:
	var result := PackedByteArray()
	var offset := 0
	while offset < data.size():
		var chunk_size := mini(255, data.size() - offset)
		result.append(chunk_size)
		result.append_array(data.slice(offset, offset + chunk_size))
		offset += chunk_size
	result.append(0) # Block terminator
	return result


# =============================================================================
# Helpers
# =============================================================================


static func _append_le16(buffer: PackedByteArray, value: int) -> void:
	buffer.append(value & 0xFF)
	buffer.append((value >> 8) & 0xFF)
