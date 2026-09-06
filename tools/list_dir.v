module tools

import os
import strings

fn tool_list_dir(args map[string]string) ToolResult {
	base_path := if 'path' in args { args['path'] } else { '.' }
	resolved := resolve_path(base_path)

	entries := os.ls(resolved) or {
		return ToolResult{
			content:  'Error listing directory: ${err}'
			is_error: true
		}
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
	return ToolResult{
		content:  sb.str()
		is_error: false
	}
}
