module tools

import os

fn tool_write(args map[string]string) ToolResult {
	path := args['path'] or { '' }
	if path == '' {
		return ToolResult{
			content:  'Error: path is required'
			is_error: true
		}
	}
	content := args['content'] or { '' }

	lock_file_mutation()
	defer { unlock_file_mutation() }

	resolved := resolve_path(path)
	parent := os.dir(resolved)
	if parent != '' && parent != '.' {
		os.mkdir_all(parent) or {
			return ToolResult{
				content:  'Error creating directory: ${err}'
				is_error: true
			}
		}
	}

	os.write_file(resolved, content) or {
		return ToolResult{
			content:  'Error writing file: ${err}'
			is_error: true
		}
	}
	return ToolResult{
		content:  'Successfully wrote ${content.len} bytes to ${resolved}'
		is_error: false
	}
}
