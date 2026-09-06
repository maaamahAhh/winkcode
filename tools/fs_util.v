module tools

import os

// normalize_path converts all backslashes to forward slashes and trims trailing slashes.
pub fn normalize_path(path string) string {
	mut p := path.replace('\\', '/')
	for p.ends_with('/') && p.len > 1 {
		if p.len == 3 && p[1] == `:` {
			break
		}
		p = p[..p.len - 1]
	}
	return p
}

// wildcard_match checks if text matches a simple glob pattern supporting '*' and '?'.
// Case-insensitive on Windows.
pub fn wildcard_match(pattern string, text string) bool {
	p := pattern.to_lower()
	t := text.to_lower()
	mut pi := 0
	mut ti := 0
	mut star_pi := -1
	mut star_ti := -1

	for ti < t.len {
		if pi < p.len {
			pc := p[pi]
			tc := t[ti]
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
	for pi < p.len && p[pi] == `*` {
		pi++
	}
	return pi == p.len
}

fn match_glob_segments(p_segs []string, pi int, t_segs []string, ti int) bool {
	if pi == p_segs.len && ti == t_segs.len {
		return true
	}
	if pi == p_segs.len {
		return false
	}
	if p_segs[pi] == '**' {
		if pi + 1 == p_segs.len {
			return true
		}
		for k := ti; k <= t_segs.len; k++ {
			if match_glob_segments(p_segs, pi + 1, t_segs, k) {
				return true
			}
		}
		return false
	}
	if ti >= t_segs.len {
		return false
	}
	if wildcard_match(p_segs[pi], t_segs[ti]) {
		return match_glob_segments(p_segs, pi + 1, t_segs, ti + 1)
	}
	return false
}

// glob_match checks if a relative or absolute path matches a glob pattern (supports * and **).
pub fn glob_match(pattern string, file_path string) bool {
	norm_pattern := normalize_path(pattern).trim_space()
	norm_file := normalize_path(file_path).trim_space()

	p_segs := norm_pattern.split('/').filter(it.len > 0)
	t_segs := norm_file.split('/').filter(it.len > 0)
	return match_glob_segments(p_segs, 0, t_segs, 0)
}

pub fn matches_glob(file_path string, glob_pattern string, base_dir string) bool {
	trimmed_pattern := glob_pattern.trim_space()
	if trimmed_pattern.len == 0 {
		return false
	}

	norm_file := normalize_path(file_path)
	file_name := os.file_name(norm_file)

	// Simple filename pattern without slashes (e.g. "*.html", "test.v")
	if !trimmed_pattern.contains('/') && !trimmed_pattern.contains('\\') {
		if wildcard_match(trimmed_pattern, file_name) {
			return true
		}
	}

	// Relative path match against base_dir or current working directory
	rel := if base_dir.len > 0 {
		make_relative_to(norm_file, base_dir)
	} else {
		make_relative(norm_file)
	}

	if glob_match(trimmed_pattern, rel) {
		return true
	}

	// Full path match if pattern is absolute
	if trimmed_pattern.starts_with('/') || (trimmed_pattern.len >= 2 && trimmed_pattern[1] == `:`) {
		if glob_match(trimmed_pattern, norm_file) {
			return true
		}
	}

	return false
}

// should_skip_dir returns true if the directory is typically ignored (e.g. .git, node_modules).
fn should_skip_dir(name string) bool {
	return name in [
		'.git',
		'node_modules',
		'.svn',
		'.hg',
		'venv',
		'.venv',
		'target',
		'dist',
		'build',
		'bin',
		'obj',
		'.next',
		'.nuxt',
		'.cache',
		'__pycache__',
	]
}

// collect_files_recursive collects all file paths under base recursively.
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

// make_relative returns the relative path from current working directory.
pub fn make_relative(file string) string {
	return make_relative_to(file, os.getwd())
}

// make_relative_to returns the relative path of file relative to base.
pub fn make_relative_to(file string, base string) string {
	norm_file := normalize_path(file)
	norm_base := normalize_path(base)
	prefix := norm_base + '/'
	if norm_file.to_lower().starts_with(prefix.to_lower()) {
		return norm_file[prefix.len..]
	}
	return norm_file
}
