module tools

import os
import strings

fn tool_glob(args map[string]string) ToolResult {
	pattern := args['pattern'] or { '' }
	if pattern.trim_space() == '' {
		return ToolResult{
			content:  'Error: pattern is required'
			is_error: true
		}
	}

	base_path := if 'path' in args { args['path'] } else { '.' }
	resolved := resolve_path(base_path)
	if !os.exists(resolved) {
		return ToolResult{
			content:  'Error: directory not found: ${base_path}'
			is_error: true
		}
	}
	files := collect_files_recursive(resolved)

	mut sb := strings.new_builder(4096)
	mut count := 0

	for file in files {
		if count >= 1000 {
			break
		}
		if matches_glob(file, pattern, resolved) {
			rel := make_relative(file)
			sb.writeln(rel)
			count++
		}
	}

	if count == 0 {
		return ToolResult{
			content:  'No files matched'
			is_error: false
		}
	}
	return ToolResult{
		content:  sb.str()
		is_error: false
	}
}
