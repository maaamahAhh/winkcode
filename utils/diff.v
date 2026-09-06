module utils

struct DiffChunk {
	kind string // ' ', '-', '+'
	text string
}

fn pad_left(n int, width int) string {
	s := n.str()
	return if s.len < width { ' '.repeat(width - s.len) + s } else { s }
}

fn diff_lines(a []string, b []string) []DiffChunk {
	n := a.len
	m := b.len

	// Trim common prefix
	mut prefix_len := 0
	for prefix_len < n && prefix_len < m && a[prefix_len] == b[prefix_len] {
		prefix_len++
	}

	// Trim common suffix
	mut suffix_len := 0
	for suffix_len < (n - prefix_len) && suffix_len < (m - prefix_len)
		&& a[n - 1 - suffix_len] == b[m - 1 - suffix_len] {
		suffix_len++
	}

	mut chunks := []DiffChunk{cap: n + m}
	for i in 0 .. prefix_len {
		chunks << DiffChunk{kind: ' ', text: a[i]}
	}

	mid_a := a[prefix_len..n - suffix_len]
	mid_b := b[prefix_len..m - suffix_len]

	if mid_a.len > 0 || mid_b.len > 0 {
		mid_diff := lcs_diff(mid_a, mid_b)
		for c in mid_diff {
			chunks << c
		}
	}

	for i in (n - suffix_len) .. n {
		chunks << DiffChunk{kind: ' ', text: a[i]}
	}

	return chunks
}

fn lcs_diff(a []string, b []string) []DiffChunk {
	n := a.len
	m := b.len

	if n == 0 {
		mut res := []DiffChunk{cap: m}
		for s in b {
			res << DiffChunk{kind: '+', text: s}
		}
		return res
	}
	if m == 0 {
		mut res := []DiffChunk{cap: n}
		for s in a {
			res << DiffChunk{kind: '-', text: s}
		}
		return res
	}

	// Guard against massive allocation in extreme cases
	mid_product := i64(n) * i64(m)
	if mid_product > 250_000 {
		mut res := []DiffChunk{cap: n + m}
		for s in a {
			res << DiffChunk{kind: '-', text: s}
		}
		for s in b {
			res << DiffChunk{kind: '+', text: s}
		}
		return res
	}

	// DP table for LCS
	mut dp := [][]int{len: n + 1, init: []int{len: m + 1, init: 0}}
	for i in 0 .. n {
		for j in 0 .. m {
			if a[i] == b[j] {
				dp[i + 1][j + 1] = dp[i][j] + 1
			} else {
				dp[i + 1][j + 1] = if dp[i + 1][j] > dp[i][j + 1] { dp[i + 1][j] } else { dp[i][j + 1] }
			}
		}
	}

	// Backtrack
	mut mut_chunks := []DiffChunk{}
	mut i := n
	mut j := m
	for i > 0 || j > 0 {
		if i > 0 && j > 0 && a[i - 1] == b[j - 1] {
			mut_chunks << DiffChunk{kind: ' ', text: a[i - 1]}
			i--
			j--
		} else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
			mut_chunks << DiffChunk{kind: '+', text: b[j - 1]}
			j--
		} else if i > 0 && (j == 0 || dp[i][j - 1] < dp[i - 1][j]) {
			mut_chunks << DiffChunk{kind: '-', text: a[i - 1]}
			i--
		}
	}

	// Reverse
	mut res := []DiffChunk{cap: mut_chunks.len}
	for k := mut_chunks.len - 1; k >= 0; k-- {
		res << mut_chunks[k]
	}
	return res
}

// format_diff generates a unified, line-numbered diff between old_content and new_content
// with context_lines lines of context surrounding changed hunks.
pub fn format_diff(old_content string, new_content string, context_lines int) string {
	old_lines := old_content.split('\n')
	new_lines := new_content.split('\n')

	chunks := diff_lines(old_lines, new_lines)

	max_line_num := if old_lines.len > new_lines.len { old_lines.len } else { new_lines.len }
	line_num_width := max_line_num.str().len

	// Mark which chunks to keep based on proximity to changes
	mut keep := []bool{len: chunks.len, init: false}
	mut has_change := false
	for i, c in chunks {
		if c.kind != ' ' {
			has_change = true
			start := if i - context_lines < 0 { 0 } else { i - context_lines }
			end := if i + context_lines + 1 > chunks.len { chunks.len } else { i + context_lines + 1 }
			for k in start .. end {
				keep[k] = true
			}
		}
	}

	if !has_change {
		return ''
	}

	pad := ' '.repeat(line_num_width)
	mut output := []string{}
	mut old_line_num := 1
	mut new_line_num := 1
	mut skipping := false
	mut has_emitted := false

	for i, c in chunks {
		if !keep[i] {
			if !skipping && has_emitted {
				output << ' ${pad} ...'
				skipping = true
			}
			if c.kind == '-' {
				old_line_num++
			} else if c.kind == '+' {
				new_line_num++
			} else {
				old_line_num++
				new_line_num++
			}
			continue
		}

		// First kept line after initial skipped lines
		if !has_emitted && (old_line_num > 1 || new_line_num > 1) {
			output << ' ${pad} ...'
		}
		has_emitted = true
		skipping = false

		match c.kind {
			'-' {
				num_str := pad_left(old_line_num, line_num_width)
				output << '-${num_str} ${c.text}'
				old_line_num++
			}
			'+' {
				num_str := pad_left(new_line_num, line_num_width)
				output << '+${num_str} ${c.text}'
				new_line_num++
			}
			else {
				num_str := pad_left(old_line_num, line_num_width)
				output << ' ${num_str} ${c.text}'
				old_line_num++
				new_line_num++
			}
		}
	}

	return output.join('\n')
}

// is_diff_content checks whether text appears to be a diff with additions and deletions or hunk headers.
pub fn is_diff_content(text string) bool {
	if text.len == 0 {
		return false
	}
	mut has_plus := false
	mut has_minus := false
	for line in text.split('\n') {
		trimmed := line.trim_space()
		if trimmed.starts_with('@@') {
			return true
		}
		if line.starts_with('+') {
			has_plus = true
		} else if line.starts_with('-') {
			has_minus = true
		}
	}
	return has_plus && has_minus
}
