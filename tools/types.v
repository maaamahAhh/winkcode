module tools

import os
import utils

pub struct ToolResult {
pub:
	content    string
	is_error   bool
	image_data ?ImageData // optional image data for multimodal models
	diff       string     // optional diff display for edit tool
}

pub struct ImageData {
pub:
	data      string // base64 encoded image data
	mime_type string // e.g. "image/png"
	name      string // display name
}

struct ToolDef {
	name        string
	description string
	params_json string // Full JSON schema for parameters
}

fn truncate_output(text string, max_chars int) string {
	if text.len <= max_chars {
		return text
	}
	return utils.safe_truncate(text, max_chars) + '\n...[truncated]...'
}

fn resolve_path(path string) string {
	if path == '' {
		return path
	}
	mut p := path
	if p.starts_with('~') {
		p = os.home_dir() + p[1..]
	}
	return os.real_path(p)
}
