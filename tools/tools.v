module tools

import os
import strings
import encoding.base64

fn encode_base64(data []u8) string {
	return base64.encode(data)
}

pub struct ToolResult {
pub:
	content     string
	is_error    bool
	image_data  ?ImageData // optional image data for multimodal models
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
	return text[..max_chars] + '\n...[truncated]...'
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

fn pad_left(s string, width int) string {
	if s.len >= width {
		return s
	}
	return ' '.repeat(width - s.len) + s
}

fn wildcard_match(pattern string, text string) bool {
	mut pi := 0
	mut ti := 0
	mut star_pi := -1
	mut star_ti := -1

	for ti < text.len {
		if pi < pattern.len {
			pc := pattern[pi]
			tc := text[ti]
			if pc == `*` {
				star_pi = pi
				star_ti = ti
				pi++
				continue
			}
			if pc == `?` || pc == tc {
				pi++
				ti++
				continue
			}
		}
		if star_pi >= 0 {
			pi = star_pi + 1
			star_ti++
			ti = star_ti
			continue
		}
		return false
	}
	for pi < pattern.len && pattern[pi] == `*` {
		pi++
	}
	return pi == pattern.len
}

fn should_skip_dir(name string) bool {
	return name == '.git' || name == 'node_modules' || name == '.svn'
}

fn collect_files_recursive(base string) []string {
	mut files := []string{}
	mut dirs := [base]

	for dirs.len > 0 {
		mut dir := dirs.pop()
		entries := os.ls(dir) or { continue }
		for entry in entries {
			full := os.join_path(dir, entry)
			if os.is_dir(full) {
				if !should_skip_dir(entry) {
					dirs << full
				}
			} else if os.is_file(full) {
				files << full
			}
		}
	}
	return files
}

fn matches_glob(file_path string, glob_pattern string) bool {
	name := os.file_name(file_path)
	return wildcard_match(glob_pattern, name)
}

fn make_relative(file string) string {
	cwd := os.getwd()
	prefix := cwd + os.path_separator
	if file.starts_with(prefix) {
		return file[prefix.len..]
	}
	return file
}

// --- Tool implementations ---

fn tool_read(args map[string]string) ToolResult {
	path := args['path'] or { '' }
	if path == '' {
		return ToolResult{content: 'Error: path is required', is_error: true}
	}

	resolved := resolve_path(path)
	
	// Check if file is an image
	ext := resolved.all_after_last('.').to_lower()
	image_exts := ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'svg', 'ico']
	if ext in image_exts {
		if !os.exists(resolved) {
			return ToolResult{content: 'Error: file not found: ${resolved}', is_error: true}
		}
		content := os.read_file(resolved) or {
			return ToolResult{content: 'Error reading image: ${err}', is_error: true}
		}
		base64_data := encode_base64(content.bytes())
		mime_type := 'image/${ext}'
		display_name := os.file_name(resolved)
		return ToolResult{
			content: '[Image: ${display_name}]\nSize: ${content.len} bytes'
			is_error: false
			image_data: ImageData{
				data: base64_data
				mime_type: mime_type
				name: display_name
			}
		}
	}
	
	content := os.read_file(resolved) or {
		return ToolResult{content: 'Error reading file: ${err}', is_error: true}
	}

	lines := content.split('\n')
	mut offset := if 'offset' in args { args['offset'].int() } else { 1 }
	limit := if 'limit' in args { args['limit'].int() } else { lines.len }

	if offset < 1 {
		offset = 1
	}
	start := offset - 1
	if start >= lines.len {
		return ToolResult{content: 'Error: offset beyond file length', is_error: true}
	}

	mut end := start + limit
	if end > lines.len {
		end = lines.len
	}

	num_width := end.str().len

	mut sb := strings.new_builder(end - start * 64)
	for i in start .. end {
		line_num := pad_left((i + 1).str(), num_width)
		sb.writeln('${line_num}→${lines[i]}')
	}
	return ToolResult{content: sb.str(), is_error: false}
}

fn tool_write(args map[string]string) ToolResult {
	path := args['path'] or { '' }
	if path == '' {
		return ToolResult{content: 'Error: path is required', is_error: true}
	}
	content := args['content'] or { '' }

	resolved := resolve_path(path)
	parent := os.dir(resolved)
	if parent != '' && parent != '.' {
		os.mkdir_all(parent) or {
			return ToolResult{content: 'Error creating directory: ${err}', is_error: true}
		}
	}

	os.write_file(resolved, content) or {
		return ToolResult{content: 'Error writing file: ${err}', is_error: true}
	}
	return ToolResult{content: 'Wrote ${content.len} chars to ${resolved}', is_error: false}
}

fn tool_edit(args map[string]string) ToolResult {
	path := args['path'] or { '' }
	old_text := args['old_text'] or { '' }
	new_text := args['new_text'] or { '' }

	if path == '' {
		return ToolResult{content: 'Error: path is required', is_error: true}
	}
	if old_text == '' {
		return ToolResult{content: 'Error: old_text cannot be empty', is_error: true}
	}

	resolved := resolve_path(path)
	raw := os.read_file(resolved) or {
		return ToolResult{content: 'Error reading file: ${err}', is_error: true}
	}

	had_crlf := raw.contains('\r\n')
	normalized := raw.replace('\r\n', '\n')
	normalized_old := old_text.replace('\r\n', '\n')
	normalized_new := new_text.replace('\r\n', '\n')

	count := normalized.count(normalized_old)
	if count == 0 {
		return ToolResult{content: 'Error: old_text not found in file', is_error: true}
	}
	if count > 1 {
		return ToolResult{content: 'Error: old_text found ${count} times, must be unique', is_error: true}
	}

	result := normalized.replace_once(normalized_old, normalized_new)

	if result == normalized {
		return ToolResult{content: 'Error: no change made (old_text == new_text)', is_error: true}
	}

	final_content := if had_crlf { result.replace('\n', '\r\n') } else { result }

	os.write_file(resolved, final_content) or {
		return ToolResult{content: 'Error writing file: ${err}', is_error: true}
	}
	return ToolResult{content: 'Edited ${resolved}', is_error: false}
}

fn tool_bash(args map[string]string) ToolResult {
	cmd := args['command'] or { '' }
	if cmd == '' {
		return ToolResult{content: 'Error: command is required', is_error: true}
	}

	mut timeout := if 'timeout' in args { args['timeout'].int() } else { 120 }
	if timeout <= 0 {
		timeout = 120
	}

	result := os.execute('bash -c ' + cmd)
	mut output := result.output
	if output.len > 50000 {
		output = truncate_output(output, 50000)
	}

	if result.exit_code != 0 {
		return ToolResult{
			content: 'Exit code: ${result.exit_code}\n${output}'
			is_error: true
		}
	}
	return ToolResult{content: output, is_error: false}
}

fn tool_pwsh(args map[string]string) ToolResult {
	cmd := args['command'] or { '' }
	if cmd == '' {
		return ToolResult{content: 'Error: command is required', is_error: true}
	}

	mut timeout := if 'timeout' in args { args['timeout'].int() } else { 120 }
	if timeout <= 0 {
		timeout = 120
	}

	result := os.execute('powershell -NoProfile -Command ' + cmd)
	mut output := result.output
	if output.len > 50000 {
		output = truncate_output(output, 50000)
	}

	if result.exit_code != 0 {
		return ToolResult{
			content: 'Exit code: ${result.exit_code}\n${output}'
			is_error: true
		}
	}
	return ToolResult{content: output, is_error: false}
}

fn tool_cmd(args map[string]string) ToolResult {
	cmd := args['command'] or { '' }
	if cmd == '' {
		return ToolResult{content: 'Error: command is required', is_error: true}
	}

	mut timeout := if 'timeout' in args { args['timeout'].int() } else { 120 }
	if timeout <= 0 {
		timeout = 120
	}

	result := os.execute(cmd)
	mut output := result.output
	if output.len > 50000 {
		output = truncate_output(output, 50000)
	}

	if result.exit_code != 0 {
		return ToolResult{
			content: 'Exit code: ${result.exit_code}\n${output}'
			is_error: true
		}
	}
	return ToolResult{content: output, is_error: false}
}

fn tool_grep(args map[string]string) ToolResult {
	pattern := args['pattern'] or { '' }
	if pattern == '' {
		return ToolResult{content: 'Error: pattern is required', is_error: true}
	}

	base_path := if 'path' in args { args['path'] } else { '.' }
	glob_pattern := if 'glob' in args { args['glob'] } else { '' }
	ignore_case := if 'ignore_case' in args { args['ignore_case'] == 'true' } else { false }
	mut limit := if 'limit' in args { args['limit'].int() } else { 100 }
	if limit <= 0 {
		limit = 100
	}

	resolved := resolve_path(base_path)
	files := collect_files_recursive(resolved)

	search_pattern := if ignore_case { pattern.to_lower() } else { pattern }
	mut sb := strings.new_builder(4096)
	mut match_count := 0

	for file in files {
		if match_count >= limit {
			break
		}
		if glob_pattern != '' && !matches_glob(file, glob_pattern) {
			continue
		}

		content := os.read_file(file) or { continue }
		lines := content.split('\n')
		rel := make_relative(file)

		for i, line in lines {
			if match_count >= limit {
				break
			}
			check := if ignore_case { line.to_lower() } else { line }
			if check.contains(search_pattern) {
				sb.writeln('${rel}:${i + 1}: ${line}')
				match_count++
			}
		}
	}

	if match_count == 0 {
		return ToolResult{content: 'No matches found', is_error: false}
	}
	return ToolResult{content: sb.str(), is_error: false}
}

fn tool_glob(args map[string]string) ToolResult {
	pattern := args['pattern'] or { '' }
	if pattern == '' {
		return ToolResult{content: 'Error: pattern is required', is_error: true}
	}

	base_path := if 'path' in args { args['path'] } else { '.' }
	resolved := resolve_path(base_path)
	files := collect_files_recursive(resolved)

	mut sb := strings.new_builder(4096)
	mut count := 0

	for file in files {
		if count >= 1000 {
			break
		}
		if matches_glob(file, pattern) {
			rel := make_relative(file)
			sb.writeln(rel)
			count++
		}
	}

	if count == 0 {
		return ToolResult{content: 'No files matched', is_error: false}
	}
	return ToolResult{content: sb.str(), is_error: false}
}

fn tool_list_dir(args map[string]string) ToolResult {
	base_path := if 'path' in args { args['path'] } else { '.' }
	resolved := resolve_path(base_path)

	entries := os.ls(resolved) or {
		return ToolResult{content: 'Error listing directory: ${err}', is_error: true}
	}

	mut dirs := []string{}
	mut files := []string{}

	for entry in entries {
		full := os.join_path(resolved, entry)
		if os.is_dir(full) {
			dirs << entry + '/'
		} else {
			files << entry
		}
	}

	dirs.sort()
	files.sort()

	mut sb := strings.new_builder(entries.len * 32)
	for d in dirs {
		sb.writeln(d)
	}
	for f in files {
		sb.writeln(f)
	}
	return ToolResult{content: sb.str(), is_error: false}
}

// --- Schema and dispatch ---

fn tool_definitions() []ToolDef {
	return [
		ToolDef{
			name: 'read'
			description: 'Read file contents with optional line offset and limit'
			params_json: '{"type":"object","properties":{"path":{"type":"string","description":"File path to read"},"offset":{"type":"integer","description":"1-indexed line number to start from"},"limit":{"type":"integer","description":"Number of lines to read"}},"required":["path"]}'
		},
		ToolDef{
			name: 'write'
			description: 'Write content to a file, creating parent directories if needed'
			params_json: '{"type":"object","properties":{"path":{"type":"string","description":"File path to write"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}'
		},
		ToolDef{
			name: 'edit'
			description: 'Exact string replacement in a file. Fails if old_text is not found or not unique.'
			params_json: '{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"old_text":{"type":"string","description":"Exact text to find and replace"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path","old_text","new_text"]}'
		},
		ToolDef{
			name: 'bash'
			description: 'Execute a bash command and return output'
			params_json: '{"type":"object","properties":{"command":{"type":"string","description":"Bash command to execute"},"timeout":{"type":"integer","description":"Timeout in seconds (default 120)"}},"required":["command"]}'
		},
		ToolDef{
			name: 'pwsh'
			description: 'Execute a PowerShell command and return output'
			params_json: '{"type":"object","properties":{"command":{"type":"string","description":"PowerShell command to execute"},"timeout":{"type":"integer","description":"Timeout in seconds (default 120)"}},"required":["command"]}'
		},
		ToolDef{
			name: 'cmd'
			description: 'Execute a cmd.exe command and return output'
			params_json: '{"type":"object","properties":{"command":{"type":"string","description":"Command to execute via cmd /C"},"timeout":{"type":"integer","description":"Timeout in seconds (default 120)"}},"required":["command"]}'
		},
		ToolDef{
			name: 'grep'
			description: 'Search file contents for a pattern'
			params_json: '{"type":"object","properties":{"pattern":{"type":"string","description":"Search pattern"},"path":{"type":"string","description":"Directory to search in (default .)"},"glob":{"type":"string","description":"File name glob pattern to filter"},"ignore_case":{"type":"boolean","description":"Case insensitive search"},"limit":{"type":"integer","description":"Max results (default 100)"}},"required":["pattern"]}'
		},
		ToolDef{
			name: 'glob'
			description: 'Find files matching a glob pattern'
			params_json: '{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (supports * and ?)"},"path":{"type":"string","description":"Directory to search in (default .)"}},"required":["pattern"]}'
		},
		ToolDef{
			name: 'list_dir'
			description: 'List directory contents, directories first with / suffix'
			params_json: '{"type":"object","properties":{"path":{"type":"string","description":"Directory path (default .)"}},"required":[]}'
		},
	]
}

// Anthropic format: [{"name":"...","description":"...","input_schema":{...}}]
pub fn get_schemas() string {
	defs := tool_definitions()
	mut sb := strings.new_builder(4096)
	sb.writeln('[')
	for i, def in defs {
		if i > 0 {
			sb.writeln(',')
		}
		sb.writeln('{"name":"${def.name}","description":"${def.description}","input_schema":${def.params_json}}')
	}
	sb.writeln(']')
	return sb.str()
}

// OpenAI format: [{"type":"function","function":{"name":"...","description":"...","parameters":{...}}}]
pub fn get_schemas_openai() string {
	defs := tool_definitions()
	mut sb := strings.new_builder(4096)
	sb.writeln('[')
	for i, def in defs {
		if i > 0 {
			sb.writeln(',')
		}
		sb.writeln('{"type":"function","function":{"name":"${def.name}","description":"${def.description}","parameters":${def.params_json}}}')
	}
	sb.writeln(']')
	return sb.str()
}

pub fn merge_schemas(a string, b string) string {
	if a.len == 0 {
		return b
	}
	if b.len == 0 {
		return a
	}
	mut a_content := a.trim_space().trim('[]')
	mut b_content := b.trim_space().trim('[]')
	if a_content.len > 0 && b_content.len > 0 {
		return '[${a_content},${b_content}]'
	} else if a_content.len > 0 {
		return '[${a_content}]'
	} else {
		return '[${b_content}]'
	}
}

pub fn execute_tool(name string, args map[string]string) ToolResult {
	match name {
		'read' { return tool_read(args) }
		'write' { return tool_write(args) }
		'edit' { return tool_edit(args) }
		'bash' { return tool_bash(args) }
		'pwsh' { return tool_pwsh(args) }
		'cmd' { return tool_cmd(args) }
		'grep' { return tool_grep(args) }
		'glob' { return tool_glob(args) }
		'list_dir' { return tool_list_dir(args) }
		else { return ToolResult{content: 'Unknown tool: ${name}', is_error: true} }
	}
}
