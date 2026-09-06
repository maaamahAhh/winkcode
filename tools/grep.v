module tools

import os
import strings


fn tool_grep(args map[string]string) ToolResult {
	pattern := args['pattern'] or { '' }
	if pattern == '' {
		return ToolResult{
			content:  'Error: pattern is required'
			is_error: true
		}
	}

	base_path := if 'path' in args { args['path'] } else { '.' }
	glob_pattern := if 'glob' in args { args['glob'] } else { '' }
	ignore_case := if 'ignore_case' in args { args['ignore_case'] == 'true' } else { false }
	mut limit := if 'limit' in args { args['limit'].int() } else { 100 }
	if limit <= 0 {
		limit = 100
	}

	resolved := resolve_path(base_path)
	files := if os.is_file(resolved) {
		[resolved]
	} else if os.is_dir(resolved) {
		collect_files_recursive(resolved)
	} else {
		[]string{}
	}

	search_pattern := if ignore_case { pattern.to_lower() } else { pattern }
	mut sb := strings.new_builder(4096)
	mut match_count := 0

	for file in files {
		if match_count >= limit {
			break
		}
		if glob_pattern != '' && !matches_glob(file, glob_pattern, resolved) {
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
		return ToolResult{
			content:  'No matches found'
			is_error: false
		}
	}
	return ToolResult{
		content:  sb.str()
		is_error: false
	}
}
