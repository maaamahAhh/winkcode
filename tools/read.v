module tools

import os
import strings
import encoding.base64

fn encode_base64(data []u8) string {
	return base64.encode(data)
}

fn pad_left(s string, width int) string {
	if s.len >= width {
		return s
	}
	return ' '.repeat(width - s.len) + s
}

fn tool_read(args map[string]string) ToolResult {
	path := args['path'] or { '' }
	if path == '' {
		return ToolResult{
			content:  'Error: path is required'
			is_error: true
		}
	}

	resolved := resolve_path(path)
	ext := resolved.all_after_last('.').to_lower()
	image_exts := ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'svg', 'ico']
	audio_exts := ['mp3', 'wav', 'ogg', 'm4a']
	video_exts := ['mp4', 'webm', 'mov']

	is_image := ext in image_exts
	is_audio := ext in audio_exts
	is_video := ext in video_exts

	if is_image || is_audio || is_video {
		if !os.exists(resolved) {
			return ToolResult{
				content:  'Error: file not found: ${resolved}'
				is_error: true
			}
		}
		media_size := os.file_size(resolved)
		if media_size > 50 * 1024 * 1024 {
			return ToolResult{
				content:  'Error: media file is too large (${media_size} bytes, max 50MB)'
				is_error: true
			}
		}
		media_bytes := os.read_bytes(resolved) or {
			return ToolResult{
				content:  'Error reading media file: ${err}'
				is_error: true
			}
		}
		base64_data := encode_base64(media_bytes)
		mime_type := match ext {
			'jpg', 'jpeg' { 'image/jpeg' }
			'png' { 'image/png' }
			'gif' { 'image/gif' }
			'webp' { 'image/webp' }
			'svg' { 'image/svg+xml' }
			'bmp' { 'image/bmp' }
			'ico' { 'image/x-icon' }
			'mp3' { 'audio/mpeg' }
			'wav' { 'audio/wav' }
			'ogg' { 'audio/ogg' }
			'm4a' { 'audio/mp4' }
			'mp4' { 'video/mp4' }
			'webm' { 'video/webm' }
			'mov' { 'video/quicktime' }
			else {
				if is_audio {
					'audio/${ext}'
				} else if is_video {
					'video/${ext}'
				} else {
					'image/${ext}'
				}
			}
		}
		display_name := os.file_name(resolved)
		media_kind := if is_audio {
			'Audio'
		} else if is_video { 'Video' } else { 'Image' }
		return ToolResult{
			content:    '[${media_kind}: ${display_name}]\nSize: ${media_bytes.len} bytes'
			is_error:   false
			image_data: ImageData{
				data:      base64_data
				mime_type: mime_type
				name:      display_name
			}
		}
	}

	if !os.exists(resolved) {
		return ToolResult{
			content:  'Error: file not found: ${resolved}'
			is_error: true
		}
	}
	size := os.file_size(resolved)
	if size > 10 * 1024 * 1024 {
		return ToolResult{
			content:  'Error: file is too large (${size} bytes, max 10MB). Use offset and limit or external tools to inspect.'
			is_error: true
		}
	}

	content := os.read_file(resolved) or {
		return ToolResult{
			content:  'Error reading file: ${err}'
			is_error: true
		}
	}

	lines := content.split('\n')
	mut offset := if 'offset' in args { args['offset'].int() } else { 1 }
	mut limit := if 'limit' in args { args['limit'].int() } else { lines.len }

	if offset < 1 {
		offset = 1
	}
	if limit < 0 {
		limit = 0
	}
	start := offset - 1
	if start >= lines.len {
		return ToolResult{
			content:  'Error: offset beyond file length'
			is_error: true
		}
	}

	mut end := start + limit
	if end > lines.len {
		end = lines.len
	}
	if end < start {
		end = start
	}

	num_width := end.str().len

	mut sb := strings.new_builder((end - start) * 64)
	for i in start .. end {
		line_num := pad_left((i + 1).str(), num_width)
		sb.writeln('${line_num}→${lines[i]}')
	}
	return ToolResult{
		content:  truncate_output(sb.str(), 100_000)
		is_error: false
	}
}
