module tui

import term.ui as termui
import strings

// === Visual width helpers ===

fn is_narrow_unicode(r rune) bool {
	return (r >= 0x2500 && r <= 0x259f) || (r >= 0x25a0 && r <= 0x25ff)
		|| (r >= 0x2600 && r <= 0x27bf) || (r >= 0x2800 && r <= 0x28ff)
}

fn visual_width_char(r rune) int {
	if r <= 127 {
		return 1
	}
	if is_narrow_unicode(r) {
		return 1
	}
	return 2
}

// strip_ansi removes ANSI escape sequences (e.g. \x1b[32m) from text.
pub fn strip_ansi(s string) string {
	if !s.contains('\x1b') {
		return s
	}
	mut sb := strings.new_builder(s.len)
	mut i := 0
	for i < s.len {
		if s[i] == 0x1b && i + 1 < s.len && s[i + 1] == `[` {
			i += 2
			for i < s.len && ((s[i] >= `0` && s[i] <= `9`) || s[i] == `;` || s[i] == `?`) {
				i++
			}
			if i < s.len {
				i++ // skip ending byte (e.g. 'm', 'K', etc.)
			}
		} else {
			sb.write_u8(s[i])
			i++
		}
	}
	return sb.str()
}

pub fn visual_width(text string) int {
	clean := if text.contains('\x1b') { strip_ansi(text) } else { text }
	mut w := 0
	for r in clean.runes() {
		w += visual_width_char(r)
	}
	return w
}

pub fn truncate_by_width(text string, max_width int) string {
	if max_width <= 0 {
		return ''
	}
	clean := if text.contains('\x1b') { strip_ansi(text) } else { text }
	mut w := 0
	mut out := []rune{}
	for r in clean.runes() {
		inc := visual_width_char(r)
		if w + inc > max_width {
			break
		}
		out << r
		w += inc
	}
	return out.string()
}

pub fn tail_by_width(text string, max_width int) string {
	if max_width <= 0 {
		return ''
	}
	clean := if text.contains('\x1b') { strip_ansi(text) } else { text }
	runes := clean.runes()
	mut w := 0
	mut start_idx := runes.len
	for i := runes.len - 1; i >= 0; i-- {
		inc := visual_width_char(runes[i])
		if w + inc > max_width {
			break
		}
		w += inc
		start_idx = i
	}
	return runes[start_idx..].string()
}

pub fn wrap_text(text string, width int, max_lines int) []string {
	if width <= 0 || max_lines <= 0 {
		return []string{}
	}
	clean := if text.contains('\x1b') { strip_ansi(text) } else { text }
	mut lines := []string{}
	for raw_line in clean.split('\n') {
		if raw_line.len == 0 {
			lines << ''
			if lines.len >= max_lines {
				return lines[..max_lines]
			}
			continue
		}
		mut current := []rune{}
		mut current_width := 0
		for r in raw_line.runes() {
			inc := visual_width_char(r)
			if current_width + inc > width {
				lines << current.string()
				if lines.len >= max_lines {
					return lines[..max_lines]
				}
				current = []rune{}
				current_width = 0
			}
			current << r
			current_width += inc
		}
		if current.len > 0 {
			lines << current.string()
			if lines.len >= max_lines {
				return lines[..max_lines]
			}
		}
	}
	return lines
}

// wrap_segments folds inline segments to width, keeping per-segment
// colors. Callers prefix each line via prefix_line.
fn wrap_segments(segments []RenderLine, width int, max_lines int) []RenderLine {
	if width <= 0 || max_lines <= 0 {
		return []RenderLine{}
	}
	mut rs := []rune{}
	mut cs := []string{}
	for seg in segments {
		for r in seg.text.runes() {
			rs << r
			cs << seg.color
		}
	}
	mut lines := []RenderLine{}
	mut cr := []rune{}
	mut cc := []string{}
	mut w := 0
	for i, r in rs {
		inc := visual_width_char(r)
		if w + inc > width {
			lines << build_seg_line(cr, cc)
			if lines.len >= max_lines {
				return lines[..max_lines]
			}
			cr = []rune{}
			cc = []string{}
			w = 0
		}
		cr << r
		cc << cs[i]
		w += inc
	}
	if cr.len > 0 {
		lines << build_seg_line(cr, cc)
	}
	return lines
}

// build_seg_line groups runes by color into segments.
fn build_seg_line(runes []rune, colors []string) RenderLine {
	mut segs := []RenderLine{}
	mut seg_start := 0
	for i := 1; i <= runes.len; i++ {
		if i == runes.len || colors[i] != colors[seg_start] {
			segs << RenderLine{
				text:  runes[seg_start..i].string()
				color: colors[seg_start]
			}
			seg_start = i
		}
	}
	mut text := ''
	for seg in segs {
		text += seg.text
	}
	return RenderLine{
		text:  text
		color: segs[0].color
		segs:  segs
	}
}

// === Theme Colors ===
// All UI colors flow through theme_color so the palette stays consistent
// and can be tuned in one place.

struct ThemeColor {
	r u8
	g u8
	b u8
}

fn theme_color(name string) ThemeColor {
	return match name {
		'accent' { ThemeColor{255, 204, 0} } // wink yellow
		'yellow' { ThemeColor{255, 220, 120} } // soft yellow
		'dim' { ThemeColor{130, 120, 90} } // muted warm gray
		'text' { ThemeColor{240, 240, 240} }
		'gray' { ThemeColor{150, 150, 150} }
		'border' { ThemeColor{110, 95, 40} } // warm brown border
		'border_focus' { ThemeColor{255, 214, 0} } // bright yellow focus
		'tool_running' { ThemeColor{90, 160, 255} } // streaming tool call (blue)
		'tool_done' { ThemeColor{90, 220, 120} } // finished tool call (green)
		'thinking' { ThemeColor{200, 170, 80} } // reasoning text
		'red' { ThemeColor{255, 110, 110} }
		'green' { ThemeColor{90, 220, 120} }
		'cyan' { ThemeColor{95, 215, 255} }
		'selected_bg' { ThemeColor{60, 50, 20} } // dark yellow selection
		else { ThemeColor{240, 240, 240} }
	}
}

pub fn apply_color(mut ctx termui.Context, color string) {
	c := theme_color(color)
	ctx.set_color(r: c.r, g: c.g, b: c.b)
}

// === Message styling ===

pub fn message_prefix(role string, tool_status string) string {
	return match role {
		'user' {
			'>'
		}
		'assistant' {
			'✦'
		}
		'tool_call' {
			match tool_status {
				'pending' { '⊷' }
				'success' { '✓' }
				'error' { '✗' }
				else { '⚙' }
			}
		}
		'tool_result' {
			'↵'
		}
		'tool_error' {
			'✗'
		}
		'error' {
			'✗'
		}
		'system' {
			'◆'
		}
		'compaction' {
			'◈'
		}
		else {
			'·'
		}
	}
}

pub fn message_prefix_color(role string, tool_status string) string {
	return match role {
		'user' {
			'green'
		}
		'assistant' {
			'cyan'
		}
		'tool_call' {
			match tool_status {
				'pending' { 'yellow' }
				'success' { 'green' }
				'error' { 'red' }
				else { 'yellow' }
			}
		}
		'tool_result' {
			'gray'
		}
		'tool_error' {
			'red'
		}
		'error' {
			'red'
		}
		'system' {
			'accent'
		}
		'compaction' {
			'cyan'
		}
		else {
			'gray'
		}
	}
}

pub fn message_text_color(role string) string {
	return match role {
		'error' { 'red' }
		'tool_error' { 'red' }
		'tool_result' { 'tool_done' }
		'tool_call' { 'yellow' }
		'system' { 'yellow' }
		else { 'white' }
	}
}

// === Markdown rendering ===

struct InlineFormatRule {
	delim string
	color string
}

fn match_inline_delim(runes []rune, idx int, delim string) bool {
	d_runes := delim.runes()
	if idx + d_runes.len > runes.len {
		return false
	}
	for j, r in d_runes {
		if runes[idx + j] != r {
			return false
		}
	}
	return true
}

fn extract_inline_span(runes []rune, start int, delim string) ?(string, int) {
	if !match_inline_delim(runes, start, delim) {
		return none
	}
	d_len := delim.runes().len
	mut end := start + d_len
	for end <= runes.len - d_len {
		if match_inline_delim(runes, end, delim) {
			mut seg := []u8{}
			for j in (start + d_len) .. end {
				seg << runes[j].bytes()
			}
			return seg.bytestr(), end + d_len
		}
		end++
	}
	return none
}

// render_inline processes inline markdown formatting (code, bold, italic, strikethrough)
// and returns syntax-colored segments.
pub fn render_inline(text string) []RenderLine {
	rules := [
		InlineFormatRule{delim: '~~', color: 'red'},
		InlineFormatRule{delim: '***', color: 'yellow'},
		InlineFormatRule{delim: '**', color: 'accent'},
		InlineFormatRule{delim: '*', color: 'cyan'},
		InlineFormatRule{delim: '`', color: 'green'},
	]

	mut out := []RenderLine{}
	mut i := 0
	runes := text.runes()
	for i < runes.len {
		mut matched := false
		for rule in rules {
			if span_text, next_i := extract_inline_span(runes, i, rule.delim) {
				out << RenderLine{
					text:  span_text
					color: rule.color
				}
				i = next_i
				matched = true
				break
			}
		}
		if matched {
			continue
		}
		mut seg := []u8{}
		seg << runes[i].bytes()
		out << RenderLine{
			text:  seg.bytestr()
			color: 'white'
		}
		i++
	}
	// Merge adjacent segments with the same color
	if out.len <= 1 {
		return out
	}
	mut merged := []RenderLine{}
	merged << out[0]
	for k := 1; k < out.len; k++ {
		if merged[merged.len - 1].color == out[k].color {
			prev := merged[merged.len - 1]
			merged[merged.len - 1] = RenderLine{
				text:  prev.text + out[k].text
				color: prev.color
			}
		} else {
			merged << out[k]
		}
	}
	return merged
}

pub fn render_thinking(text string, width int) []RenderLine {
	mut lines := []RenderLine{}
	if text.len == 0 || width <= 0 {
		return lines
	}
	lines << RenderLine{
		text:  '  ◇ thinking'
		color: 'dim'
	}
	for wrapped in wrap_text(text.trim_space(), width - 4, 8) {
		lines << RenderLine{
			text:  '    ${wrapped}'
			color: 'dim'
		}
	}
	return lines
}

fn render_heading(trimmed string) ?RenderLine {
	mut level := 0
	for level < trimmed.len && trimmed[level] == `#` {
		level++
	}
	if level < 1 || level > 6 {
		return none
	}
	text := trimmed[level..].trim_space()
	mut combined := []u8{}
	for seg in render_inline(text) {
		combined << seg.text.bytes()
	}
	return RenderLine{
		text:  '  ' + combined.bytestr()
		color: 'accent'
	}
}

fn render_list_item(trimmed string, width int) ?[]RenderLine {
	if trimmed.starts_with('- ') || trimmed.starts_with('* ') {
		text := trimmed[2..]
		mut inline := render_inline(text)
		mut prefix := '  • '
		mut result := []RenderLine{}
		for wrapped in wrap_segments(inline, width - 4, 100) {
			result << prefix_line(wrapped, prefix)
			prefix = '    '
		}
		return result
	}
	if trimmed.len > 2 && trimmed[0].is_digit() && trimmed[1] == `.` && trimmed[2] == ` ` {
		num := trimmed[..2]
		text := trimmed[3..]
		mut inline := render_inline(text)
		mut prefix := '  ${num} '
		mut result := []RenderLine{}
		for wrapped in wrap_segments(inline, width - 5, 100) {
			result << prefix_line(wrapped, prefix)
			prefix = '     '
		}
		return result
	}
	return none
}

pub fn render_markdown(text string, width int) []RenderLine {
	mut lines := []RenderLine{}
	if width <= 0 {
		return lines
	}

	raw_lines := text.split('\n')
	mut in_code_block := false
	mut code_lines := []string{}

	for i := 0; i < raw_lines.len; i++ {
		raw_line := raw_lines[i]
		trimmed := raw_line.trim_space()

		// Code block fence
		if trimmed.starts_with('```') {
			if in_code_block {
				// End of code block — render accumulated code
				lines << RenderLine{
					text:  '  ┌' + '─'.repeat(width - 4) + '┐'
					color: 'border'
				}
				for cl in code_lines {
					lines << RenderLine{
						text:  '  │ ${cl}'
						color: 'green'
					}
				}
				lines << RenderLine{
					text:  '  └' + '─'.repeat(width - 4) + '┘'
					color: 'border'
				}
				code_lines = []string{}
				in_code_block = false
			} else {
				// Start of code block
				in_code_block = true
				lang := trimmed[3..].trim_space()
				if lang.len > 0 {
					lines << RenderLine{
						text:  '  ┌ ${lang} ' + '─'.repeat(width - 6 - lang.len)
						color: 'border'
					}
				} else {
					lines << RenderLine{
						text:  '  ┌' + '─'.repeat(width - 4) + '┐'
						color: 'border'
					}
				}
			}
			continue
		}

		if in_code_block {
			code_lines << raw_line
			continue
		}

		// Headings
		if trimmed.starts_with('#') {
			if heading := render_heading(trimmed) {
				lines << heading
				continue
			}
		}

		// Blockquote
		if trimmed.starts_with('> ') {
			quote_text := trimmed[2..]
			mut inline := render_inline(quote_text)
			for wrapped in wrap_segments(inline, width - 6, 100) {
				lines << prefix_line(wrapped, '  │ ')
			}
			continue
		}

		// Horizontal rule
		if trimmed == '---' || trimmed == '***' || trimmed == '___' {
			lines << RenderLine{
				text:  '  ' + '─'.repeat(width - 2)
				color: 'border'
			}
			continue
		}

		// List items
		if list := render_list_item(trimmed, width) {
			for item in list {
				lines << item
			}
			continue
		}

		// Table detection
		if trimmed.contains('|') && i + 1 < raw_lines.len {
			next_trimmed := raw_lines[i + 1].trim_space()
			// Separator row: | --- | --- | or |:---|---:| etc.
			if next_trimmed.contains('|') && next_trimmed.contains('---') {
				mut table_rows := []string{}
				table_rows << raw_line
				// Consume separator row
				i++
				table_rows << raw_lines[i]
				// Collect data rows
				for j := i + 1; j < raw_lines.len; j++ {
					if raw_lines[j].trim_space().contains('|') {
						table_rows << raw_lines[j]
						i++
					} else {
						break
					}
				}
				for tl in render_table(table_rows, width) {
					lines << tl
				}
				continue
			}
		}

		// Empty line
		if trimmed.len == 0 {
			lines << RenderLine{
				text:  ''
				color: 'white'
			}
			continue
		}

		// Regular text with inline formatting
		mut inline := render_inline(raw_line)
		for wrapped in wrap_segments(inline, width - 2, 100) {
			lines << prefix_line(wrapped, '  ')
		}
	}

	// Unclosed code block
	if in_code_block && code_lines.len > 0 {
		for cl in code_lines {
			lines << RenderLine{
				text:  '  ${cl}'
				color: 'green'
			}
		}
	}

	return lines
}

fn render_table(rows []string, width int) []RenderLine {
	mut lines := []RenderLine{}
	if rows.len < 2 || width <= 10 {
		return lines
	}

	// Parse cells and detect alignment
	mut parsed_rows := [][]string{}
	mut col_count := 0
	mut col_align := []int{} // 0: left, 1: center, 2: right

	for r_idx, row in rows {
		mut trimmed := row.trim_space()
		if trimmed.starts_with('|') {
			trimmed = trimmed[1..]
		}
		if trimmed.ends_with('|') {
			trimmed = trimmed[..trimmed.len - 1]
		}
		cells := trimmed.split('|')
		mut row_cells := []string{}
		for cell in cells {
			row_cells << cell.trim_space()
		}
		if row_cells.len > col_count {
			col_count = row_cells.len
		}

		if r_idx == 1 {
			// Separator row: extract alignments
			for cell in row_cells {
				c := cell.trim_space()
				is_left := c.starts_with(':')
				is_right := c.ends_with(':')
				if is_left && is_right {
					col_align << 1 // center
				} else if is_right {
					col_align << 2 // right
				} else {
					col_align << 0 // left
				}
			}
		} else {
			parsed_rows << row_cells
		}
	}

	if col_count == 0 || parsed_rows.len == 0 {
		return lines
	}

	for col_align.len < col_count {
		col_align << 0
	}

	// Calculate natural width per column
	mut col_widths := []int{len: col_count, init: 4}
	for pr in parsed_rows {
		for i := 0; i < col_count; i++ {
			if i < pr.len {
				w := visual_width(pr[i])
				if w > col_widths[i] {
					col_widths[i] = w
				}
			}
		}
	}

	// Constrain widths to fit screen
	border_chars := col_count * 3 + 1 // ' │ ' dividers + borders
	max_table_content_width := width - 4 - border_chars
	if max_table_content_width < col_count * 4 {
		return lines
	}

	mut total_content_w := 0
	for cw in col_widths {
		total_content_w += cw
	}

	if total_content_w > max_table_content_width {
		scale := f32(max_table_content_width) / f32(total_content_w)
		for i := 0; i < col_widths.len; i++ {
			col_widths[i] = int(f32(col_widths[i]) * scale)
			if col_widths[i] < 4 {
				col_widths[i] = 4
			}
		}
	}

	// Helper to format a single cell line with alignment and exact visual width
	align_cell := fn (text string, target_w int, align int) string {
		vw := visual_width(text)
		if vw >= target_w {
			return truncate_by_width(text, target_w)
		}
		diff := target_w - vw
		match align {
			1 { // center
				left := diff / 2
				right := diff - left
				return ' '.repeat(left) + text + ' '.repeat(right)
			}
			2 { // right
				return ' '.repeat(diff) + text
			}
			else { // left
				return text + ' '.repeat(diff)
			}
		}
	}

	// Build border strings
	mut top_border := '  ┌'
	mut mid_border := '  ├'
	mut bot_border := '  └'
	for i := 0; i < col_count; i++ {
		w := col_widths[i] + 2
		top_border += '─'.repeat(w)
		mid_border += '─'.repeat(w)
		bot_border += '─'.repeat(w)
		if i < col_count - 1 {
			top_border += '┬'
			mid_border += '┼'
			bot_border += '┴'
		}
	}
	top_border += '┐'
	mid_border += '┤'
	bot_border += '┘'

	lines << RenderLine{
		text:  top_border
		color: 'border'
	}

	// Render each logical table row (header + data)
	for r_idx, pr in parsed_rows {
		is_header := r_idx == 0

		// Wrap each cell's text into lines matching col_widths[i]
		mut cell_lines := [][]string{}
		mut max_sub_lines := 1
		for i := 0; i < col_count; i++ {
			cell_str := if i < pr.len { pr[i] } else { '' }
			wrapped := wrap_text(cell_str, col_widths[i], 20)
			if wrapped.len > max_sub_lines {
				max_sub_lines = wrapped.len
			}
			cell_lines << wrapped
		}

		// Draw each visual line of the row
		for sub_i := 0; sub_i < max_sub_lines; sub_i++ {
			mut row_line := '  │'
			for col_i := 0; col_i < col_count; col_i++ {
				txt := if sub_i < cell_lines[col_i].len { cell_lines[col_i][sub_i] } else { '' }
				cell_str := align_cell(txt, col_widths[col_i], col_align[col_i])
				row_line += ' ' + cell_str + ' │'
			}
			lines << RenderLine{
				text:  row_line
				color: if is_header { 'accent' } else { 'white' }
			}
		}

		// Separator between header and data
		if is_header {
			lines << RenderLine{
				text:  mid_border
				color: 'border'
			}
		}
	}

	lines << RenderLine{
		text:  bot_border
		color: 'border'
	}
	return lines
}
