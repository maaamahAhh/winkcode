module tools

import os
import utils

fn tool_edit(args map[string]string) ToolResult {
	path := args['path'] or { '' }
	old_text := args['old_text'] or { '' }
	new_text := args['new_text'] or { '' }

	if path == '' {
		return ToolResult{
			content:  'Error: path is required'
			is_error: true
		}
	}
	if old_text == '' {
		return ToolResult{
			content:  'Error: old_text cannot be empty'
			is_error: true
		}
	}

	lock_file_mutation()
	defer { unlock_file_mutation() }

	resolved := resolve_path(path)
	raw := os.read_file(resolved) or {
		return ToolResult{
			content:  'Error reading file: ${err}'
			is_error: true
		}
	}

	had_crlf := raw.contains('\r\n')
	normalized := raw.replace('\r\n', '\n')
	normalized_old := old_text.replace('\r\n', '\n')
	normalized_new := new_text.replace('\r\n', '\n')

	count := normalized.count(normalized_old)
	if count == 0 {
		return ToolResult{
			content:  'Error: old_text not found in file'
			is_error: true
		}
	}
	if count > 1 {
		return ToolResult{
			content:  'Error: old_text found ${count} times, must be unique'
			is_error: true
		}
	}

	result := normalized.replace_once(normalized_old, normalized_new)

	if result == normalized {
		return ToolResult{
			content:  'Error: no change made (old_text == new_text)'
			is_error: true
		}
	}

	final_content := if had_crlf { result.replace('\n', '\r\n') } else { result }

	os.write_file(resolved, final_content) or {
		return ToolResult{
			content:  'Error writing file: ${err}'
			is_error: true
		}
	}

	diff_str := utils.format_diff(normalized, result, 3)

	return ToolResult{
		content:  'Edited ${resolved}'
		is_error: false
		diff:     diff_str
	}
}
