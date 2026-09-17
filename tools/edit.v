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
		old_lines := normalized_old.split('\n')
		mut first_non_empty := ''
		for l in old_lines {
			if l.trim_space().len > 0 {
				first_non_empty = l
				break
			}
		}

		if first_non_empty.len > 0 {
			if idx := normalized.index(first_non_empty) {
				line_no := normalized[..idx].count('\n') + 1
				preview := if first_non_empty.trim_space().len > 40 {
					first_non_empty.trim_space()[..40] + '...'
				} else {
					first_non_empty.trim_space()
				}
				return ToolResult{
					content:  'Error: old_text not found in file. The starting line "${preview}" was found at line ${line_no}, but subsequent lines differed. Check whitespace, indentation, or surrounding context.'
					is_error: true
				}
			}

			file_lines := normalized.split('\n')
			trimmed_target := first_non_empty.trim_space()
			mut approx_line := -1
			for idx, fl in file_lines {
				if fl.trim_space() == trimmed_target {
					approx_line = idx + 1
					break
				}
			}
			if approx_line > 0 {
				return ToolResult{
					content:  'Error: old_text not found in file. A line matching "${trimmed_target}" was found at line ${approx_line} but with different indentation or whitespace. Ensure exact match.'
					is_error: true
				}
			}
		}

		return ToolResult{
			content:  'Error: old_text not found in file. Read the file first to ensure the exact text and indentation are correct.'
			is_error: true
		}
	}
	if count > 1 {
		mut line_numbers := []int{}
		mut search_idx := 0
		for {
			if pos := normalized.index_after(normalized_old, search_idx) {
				line_no := normalized[..pos].count('\n') + 1
				line_numbers << line_no
				search_idx = pos + normalized_old.len
			} else {
				break
			}
		}
		lines_str := line_numbers.map(it.str()).join(', ')
		return ToolResult{
			content:  'Error: old_text found ${count} times (at lines ${lines_str}). Provide more surrounding context to make the match unique.'
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
