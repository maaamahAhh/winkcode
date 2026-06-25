module tui

import term.ui as termui

// === Visual width helpers ===

fn is_narrow_unicode(r rune) bool {
	return (r >= 0x2500 && r <= 0x259f)
		|| (r >= 0x25a0 && r <= 0x25ff)
		|| (r >= 0x2600 && r <= 0x27bf)
		|| (r >= 0x2800 && r <= 0x28ff)
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

pub fn visual_width(text string) int {
	mut w := 0
	for r in text.runes() {
		w += visual_width_char(r)
	}
	return w
}

pub fn truncate_by_width(text string, max_width int) string {
	if max_width <= 0 {
		return ''
	}
	mut w := 0
	mut out := []rune{}
	for r in text.runes() {
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
	runes := text.runes()
	mut w := 0
	mut start := runes.len
	for i := runes.len - 1; i >= 0; i-- {
		inc := visual_width_char(runes[i])
		if w + inc > max_width {
			break
		}
		w += inc
		start = i
	}
	return runes[start..].string()
}

pub fn wrap_text(text string, width int, max_lines int) []string {
	if width <= 0 || max_lines <= 0 {
		return []string{}
	}
	mut lines := []string{}
	for raw_line in text.split('\n') {
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

pub fn wrap_segments(segments []RenderLine, width int, max_lines int) []RenderLine {
	if width <= 0 || max_lines <= 0 {
		return []RenderLine{}
	}
	mut lines := []RenderLine{}
	for seg in segments {
		available := max_lines - lines.len
		if available <= 0 {
			break
		}
		for wrapped in wrap_text(seg.text, width, available) {
			if lines.len >= max_lines {
				return lines[..max_lines]
			}
			lines << RenderLine{text: wrapped, color: seg.color}
		}
	}
	return lines
}

pub fn apply_color(mut ctx termui.Context, color string) {
	match color {
		'accent' { ctx.set_color(r: 255, g: 200, b: 50) }
		'green' { ctx.set_color(r: 90, g: 220, b: 120) }
		'cyan' { ctx.set_color(r: 95, g: 215, b: 255) }
		'red' { ctx.set_color(r: 255, g: 110, b: 110) }
		'yellow' { ctx.set_color(r: 255, g: 215, b: 90) }
		'gray' { ctx.set_color(r: 150, g: 150, b: 150) }
		'dim' { ctx.set_color(r: 100, g: 100, b: 100) }
		'border' { ctx.set_color(r: 80, g: 80, b: 80) }
		'border_focus' { ctx.set_color(r: 95, g: 215, b: 255) }
		'selected_bg' { ctx.set_color(r: 50, g: 60, b: 80) }
		else { ctx.set_color(r: 240, g: 240, b: 240) }
	}
}

// === Message styling ===

pub fn message_prefix(role string, tool_status string) string {
	return match role {
		'user' { '>' }
		'assistant' { '✦' }
		'tool_call' {
			match tool_status {
				'pending' { '⊷' }
				'success' { '✓' }
				'error' { '✗' }
				else { '⚙' }
			}
		}
		'tool_result' { '↵' }
		'tool_error' { '✗' }
		'error' { '✗' }
		'system' { '◆' }
		else { '·' }
	}
}

pub fn message_prefix_color(role string, tool_status string) string {
	return match role {
		'user' { 'green' }
		'assistant' { 'cyan' }
		'tool_call' {
			match tool_status {
				'pending' { 'yellow' }
				'success' { 'green' }
				'error' { 'red' }
				else { 'yellow' }
			}
		}
		'tool_result' { 'gray' }
		'tool_error' { 'red' }
		'error' { 'red' }
		'system' { 'accent' }
		else { 'gray' }
	}
}

pub fn message_text_color(role string) string {
	return match role {
		'error' { 'red' }
		'tool_error' { 'red' }
		'tool_result' { 'dim' }
		'tool_call' { 'yellow' }
		'system' { 'yellow' }
		else { 'white' }
	}
}

// === Markdown rendering ===

// render_inline processes inline markdown and returns styled segments.
// Since term.ui doesn't support ANSI bold/italic/strikethrough, we use colors:
//   inline code: green, bold: accent, italic: cyan, bold+italic: yellow,
//   strikethrough: red, plain: white
pub fn render_inline(text string) []RenderLine {
	mut out := []RenderLine{}
	mut i := 0
	runes := text.runes()
	for i < runes.len {
		// Strikethrough: ~~text~~
		if i + 1 < runes.len && runes[i] == `~` && runes[i + 1] == `~` {
			mut end := i + 2
			for end + 1 < runes.len && !(runes[end] == `~` && runes[end + 1] == `~`) {
				end++
			}
			if end + 1 < runes.len {
				mut seg := []u8{}
				for j := i + 2; j < end; j++ {
					seg << runes[j].bytes()
				}
				out << RenderLine{text: seg.bytestr(), color: 'red'}
				i = end + 2
				continue
			}
		}
		// Bold+Italic: ***text***
		if i + 2 < runes.len && runes[i] == `*` && runes[i + 1] == `*` && runes[i + 2] == `*` {
			mut end := i + 3
			for end + 2 < runes.len && !(runes[end] == `*` && runes[end + 1] == `*` && runes[end + 2] == `*`) {
				end++
			}
			if end + 2 < runes.len {
				mut seg := []u8{}
				for j := i + 3; j < end; j++ {
					seg << runes[j].bytes()
				}
				out << RenderLine{text: seg.bytestr(), color: 'yellow'}
				i = end + 3
				continue
			}
		}
		// Bold: **text**
		if i + 1 < runes.len && runes[i] == `*` && runes[i + 1] == `*` {
			mut end := i + 2
			for end + 1 < runes.len && !(runes[end] == `*` && runes[end + 1] == `*`) {
				end++
			}
			if end + 1 < runes.len {
				mut seg := []u8{}
				for j := i + 2; j < end; j++ {
					seg << runes[j].bytes()
				}
				out << RenderLine{text: seg.bytestr(), color: 'accent'}
				i = end + 2
				continue
			}
		}
		// Italic: *text*
		if runes[i] == `*` && i + 1 < runes.len {
			mut end := i + 1
			for end < runes.len && runes[end] != `*` {
				end++
			}
			if end < runes.len {
				mut seg := []u8{}
				for j := i + 1; j < end; j++ {
					seg << runes[j].bytes()
				}
				out << RenderLine{text: seg.bytestr(), color: 'cyan'}
				i = end + 1
				continue
			}
		}
		// Inline code: `code` (backtick = 0x60)
		if runes[i] == `\x60` && i + 1 < runes.len {
			mut end := i + 1
			for end < runes.len && runes[end] != `\x60` {
				end++
			}
			if end < runes.len {
				mut seg := []u8{}
				for j := i + 1; j < end; j++ {
					seg << runes[j].bytes()
				}
				out << RenderLine{text: seg.bytestr(), color: 'green'}
				i = end + 1
				continue
			}
		}
		// Plain character
		mut seg := []u8{}
		seg << runes[i].bytes()
		out << RenderLine{text: seg.bytestr(), color: 'white'}
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
			merged[merged.len - 1] = RenderLine{text: prev.text + out[k].text, color: prev.color}
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
	lines << RenderLine{text: '  ◇ thinking', color: 'dim'}
	for wrapped in wrap_text(text.trim_space(), width - 4, 8) {
		lines << RenderLine{text: '    ${wrapped}', color: 'dim'}
	}
	return lines
}

fn render_heading(trimmed string, width int) ?RenderLine {
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
	return RenderLine{text: '  ' + combined.bytestr(), color: 'accent'}
}

fn render_list_item(trimmed string, width int) ?[]RenderLine {
	if trimmed.starts_with('- ') || trimmed.starts_with('* ') {
		text := trimmed[2..]
		mut inline := render_inline(text)
		mut prefix := '  • '
		mut result := []RenderLine{}
		for wrapped in wrap_segments(inline, width - 4, 100) {
			result << RenderLine{text: prefix + wrapped.text, color: wrapped.color}
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
			result << RenderLine{text: prefix + wrapped.text, color: wrapped.color}
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
				lines << RenderLine{text: '  ┌' + '─'.repeat(width - 4) + '┐', color: 'border'}
				for cl in code_lines {
					lines << RenderLine{text: '  │ ${cl}', color: 'green'}
				}
				lines << RenderLine{text: '  └' + '─'.repeat(width - 4) + '┘', color: 'border'}
				code_lines = []string{}
				in_code_block = false
			} else {
				// Start of code block
				in_code_block = true
				lang := trimmed[3..].trim_space()
				if lang.len > 0 {
					lines << RenderLine{text: '  ┌ ${lang} ' + '─'.repeat(width - 6 - lang.len), color: 'border'}
				} else {
					lines << RenderLine{text: '  ┌' + '─'.repeat(width - 4) + '┐', color: 'border'}
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
			if heading := render_heading(trimmed, width) {
				lines << heading
				continue
			}
		}

		// Blockquote
		if trimmed.starts_with('> ') {
			quote_text := trimmed[2..]
			mut inline := render_inline(quote_text)
			mut prefix := '  │ '
			for wrapped in wrap_segments(inline, width - 6, 100) {
				lines << RenderLine{text: prefix + wrapped.text, color: wrapped.color}
				prefix = '  │ '
			}
			continue
		}

		// Horizontal rule
		if trimmed == '---' || trimmed == '***' || trimmed == '___' {
			lines << RenderLine{text: '  ' + '─'.repeat(width - 2), color: 'border'}
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
			lines << RenderLine{text: '', color: 'white'}
			continue
		}

		// Regular text with inline formatting
		mut inline := render_inline(raw_line)
		mut prefix := '  '
		for wrapped in wrap_segments(inline, width - 2, 100) {
			lines << RenderLine{text: prefix + wrapped.text, color: wrapped.color}
			prefix = '  '
		}
	}

	// Unclosed code block
	if in_code_block && code_lines.len > 0 {
		for cl in code_lines {
			lines << RenderLine{text: '  ${cl}', color: 'green'}
		}
	}

	return lines
}

fn render_table(rows []string, width int) []RenderLine {
	mut lines := []RenderLine{}
	if rows.len < 2 || width <= 10 {
		return lines
	}

	// Parse cells from each row (split by |, trim whitespace)
	mut parsed_rows := [][]string{}
	mut col_count := 0
	for row in rows {
		// Remove leading/trailing | and split
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
		parsed_rows << row_cells
	}

	if col_count == 0 {
		return lines
	}

	// Calculate column widths (capped to leave room for borders)
	border_chars := col_count + 1  // │ on each side
	max_table_width := width - 2 - border_chars  // '  ' prefix + border chars
	mut col_widths := []int{len: col_count, init: 3}  // min 3

	for pr in parsed_rows {
		for i := 0; i < col_count; i++ {
			if i < pr.len {
				cell_w := visual_width(pr[i])
				if cell_w > col_widths[i] {
					col_widths[i] = cell_w
				}
			}
		}
	}

	// Cap total width
	mut total_width := 0
	for cw in col_widths {
		total_width += cw
	}
	if total_width > max_table_width {
		// Scale down proportionally
		scale := f32(max_table_width) / f32(total_width)
		for i := 0; i < col_widths.len; i++ {
			col_widths[i] = int(f32(col_widths[i]) * scale)
			if col_widths[i] < 3 {
				col_widths[i] = 3
			}
		}
	}

	// Helper: format cell — truncate if too long, pad with spaces if too short
	cell_text := fn (text string, w int) string {
		cell_w := visual_width(text)
		if cell_w >= w {
			return truncate_by_width(text, w)
		}
		// Right-pad with spaces to fill column width
		return text + ' '.repeat(w - cell_w)
	}

	// Build border lines
	mut top_border := '  ┌'
	mut mid_border := '  ├'
	mut bot_border := '  └'
	for i := 0; i < col_count; i++ {
		top_border += '─'.repeat(col_widths[i] + 2) + '┬'
		mid_border += '─'.repeat(col_widths[i] + 2) + '┼'
		bot_border += '─'.repeat(col_widths[i] + 2) + '┴'
	}
	top_border = top_border[..top_border.len - 1] + '┐'
	mid_border = mid_border[..mid_border.len - 1] + '┤'
	bot_border = bot_border[..bot_border.len - 1] + '┘'

	lines << RenderLine{text: top_border, color: 'border'}

	// Header row
	if parsed_rows.len > 0 {
		mut header_line := '  │'
		for i := 0; i < col_count; i++ {
			cell := if i < parsed_rows[0].len { parsed_rows[0][i] } else { '' }
			header_line += ' ' + cell_text(cell, col_widths[i]) + ' │'
		}
		lines << RenderLine{text: header_line, color: 'accent'}
	}
	lines << RenderLine{text: mid_border, color: 'border'}

	// Data rows (skip separator row at index 1)
	for ri := 2; ri < parsed_rows.len; ri++ {
		mut row_line := '  │'
		for i := 0; i < col_count; i++ {
			cell := if i < parsed_rows[ri].len { parsed_rows[ri][i] } else { '' }
			row_line += ' ' + cell_text(cell, col_widths[i]) + ' │'
		}
		lines << RenderLine{text: row_line, color: 'white'}
	}

	lines << RenderLine{text: bot_border, color: 'border'}
	return lines
}
