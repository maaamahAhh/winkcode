module tui

import clipboard

// SelectionState tracks text selection in document coordinates (across scrollback).
pub struct SelectionState {
pub mut:
	active     bool // Mouse button is currently held down and dragging
	has_sel    bool // A non-empty text selection exists
	start_line int  // Document line index in all_chat_lines (0-indexed)
	start_col  int  // Visual column (1-indexed)
	end_line   int  // Document line index in all_chat_lines (0-indexed)
	end_col    int  // Visual column (1-indexed)
}

pub struct ColRange {
pub:
	start int
	end   int
}

// NormalizedSelection represents top-to-bottom ordered selection bounds in document space.
pub struct NormalizedSelection {
pub:
	top_line int
	top_col  int
	bot_line int
	bot_col  int
}

// normalized returns the normalized (top-to-bottom) selection coordinates.
pub fn (s SelectionState) normalized() ?NormalizedSelection {
	if !s.has_sel && !s.active {
		return none
	}
	if s.start_line < s.end_line || (s.start_line == s.end_line && s.start_col <= s.end_col) {
		return NormalizedSelection{
			top_line: s.start_line
			top_col:  s.start_col
			bot_line: s.end_line
			bot_col:  s.end_col
		}
	}
	return NormalizedSelection{
		top_line: s.end_line
		top_col:  s.end_col
		bot_line: s.start_line
		bot_col:  s.start_col
	}
}

// col_range_for_line returns the start and end column (inclusive) selected on a given document line.
pub fn (ns NormalizedSelection) col_range_for_line(line_idx int, max_cols int) ?ColRange {
	if line_idx < ns.top_line || line_idx > ns.bot_line {
		return none
	}
	if ns.top_line == ns.bot_line {
		min_x := if ns.top_col <= ns.bot_col { ns.top_col } else { ns.bot_col }
		max_x := if ns.top_col >= ns.bot_col { ns.top_col } else { ns.bot_col }
		if min_x == max_x {
			return none
		}
		return ColRange{
			start: min_x
			end:   max_x
		}
	}
	if line_idx == ns.top_line {
		return ColRange{
			start: ns.top_col
			end:   max_cols
		}
	}
	if line_idx == ns.bot_line {
		return ColRange{
			start: 1
			end:   ns.bot_col
		}
	}
	return ColRange{
		start: 1
		end:   max_cols
	}
}

// start begins a new mouse drag selection at the specified document coordinate.
pub fn (mut s SelectionState) start(line_idx int, col int) {
	s.active = true
	s.has_sel = false
	s.start_line = line_idx
	s.start_col = col
	s.end_line = line_idx
	s.end_col = col
}

// drag updates current coordinates while dragging.
pub fn (mut s SelectionState) drag(line_idx int, col int) {
	if !s.active {
		return
	}
	s.end_line = line_idx
	s.end_col = col
	if s.start_line != s.end_line || s.start_col != s.end_col {
		s.has_sel = true
	}
}

// finish completes the drag operation without dropping the selection.
pub fn (mut s SelectionState) finish(line_idx int, col int) {
	s.active = false
	s.end_line = line_idx
	s.end_col = col
	if s.start_line != s.end_line || s.start_col != s.end_col {
		s.has_sel = true
	} else {
		s.has_sel = false
	}
}

// clear resets the selection state.
pub fn (mut s SelectionState) clear() {
	s.active = false
	s.has_sel = false
	s.start_line = 0
	s.start_col = 0
	s.end_line = 0
	s.end_col = 0
}

// screen_to_doc_pos maps screen (x, y) coordinates to document line index and column.
pub fn (app App) screen_to_doc_pos(x int, y int) (int, int) {
	mut line_idx := app.visible_start_doc_idx
	rel_y := y - app.chat_start_row - app.chat_indent_rows
	if rel_y > 0 {
		line_idx += rel_y
	}
	if line_idx < 0 {
		line_idx = 0
	}
	if app.all_chat_lines.len > 0 && line_idx >= app.all_chat_lines.len {
		line_idx = app.all_chat_lines.len - 1
	}

	mut col := x
	if col < 1 {
		col = 1
	}
	if col > app.chat_width {
		col = app.chat_width
	}
	return line_idx, col
}

// extract_line_selection extracts the substring of runes spanning visual columns sel_start..sel_end.
pub fn extract_line_selection(text string, sel_start int, sel_end int) string {
	if text.len == 0 || sel_start >= sel_end {
		return ''
	}
	mut cur_col := 1
	mut extracted := []rune{}
	for r in text.runes() {
		vw := visual_width_char(r)
		rune_start := cur_col
		rune_end := cur_col + vw - 1
		if rune_end >= sel_start && rune_start <= sel_end {
			extracted << r
		}
		cur_col += vw
		if cur_col > sel_end {
			break
		}
	}
	return extracted.string().trim_right(' ')
}

// copy_to_clipboard copies text to system clipboard using V standard library clipboard.
pub fn copy_to_clipboard(text string) bool {
	if text.len == 0 {
		return false
	}
	mut cb := clipboard.new()
	defer {
		cb.destroy()
	}
	return cb.copy(text)
}

// paste_from_clipboard reads text from system clipboard using V standard library clipboard.
pub fn paste_from_clipboard() string {
	mut cb := clipboard.new()
	defer {
		cb.destroy()
	}
	return cb.paste()
}

// extract_selected_text extracts full multiline text from all document chat lines within selection bounds.
pub fn (mut app App) extract_selected_text() string {
	ns := app.selection.normalized() or { return '' }
	mut extracted_lines := []string{}
	max_idx := if ns.bot_line < app.all_chat_lines.len { ns.bot_line } else { app.all_chat_lines.len - 1 }
	for idx := ns.top_line; idx <= max_idx; idx++ {
		range := ns.col_range_for_line(idx, app.chat_width) or { continue }
		extracted := extract_line_selection(app.all_chat_lines[idx].text, range.start, range.end)
		if extracted.len > 0 {
			extracted_lines << extracted
		}
	}
	return extracted_lines.join('\n').trim_space()
}

// copy_selection copies current active selection to system clipboard.
pub fn (mut app App) copy_selection() bool {
	text := app.extract_selected_text()
	if text.len == 0 {
		return false
	}
	return copy_to_clipboard(text)
}
