module tui

const slash_commands = [
	AutocompleteItem{'/model', 'show/switch model'},
	AutocompleteItem{'/effort', 'show/set effort'},
	AutocompleteItem{'/retry', 'retry the last prompt'},
	AutocompleteItem{'/help', 'show help'},
	AutocompleteItem{'/clear', 'clear conversation'},
	AutocompleteItem{'/compact', 'manually compact context'},
	AutocompleteItem{'/mcp', 'manage MCP servers'},
]

struct AutocompleteItem {
	value       string
	description string
}

// === Input view calculation ===

const max_input_visible_lines = 8

pub struct MultiLineInputView {
pub:
	lines      []string
	cursor_row int
	cursor_col int
}

// calculate_multiline_input_view splits input by \n and wraps lines according to content_width,
// returning lines and the exact cursor_row and cursor_col.
pub fn calculate_multiline_input_view(input []rune, cursor_pos int, content_width int) MultiLineInputView {
	if content_width <= 0 {
		return MultiLineInputView{
			lines:      ['']
			cursor_row: 0
			cursor_col: 0
		}
	}

	mut lines := []string{}
	mut cur_line := []rune{}
	mut cur_width := 0
	mut cursor_row := 0
	mut cursor_col := 0
	mut found_cursor := false

	for i := 0; i <= input.len; i++ {
		is_at_cursor := i == cursor_pos
		if is_at_cursor {
			cursor_row = lines.len
			cursor_col = cur_width
			found_cursor = true
		}

		if i == input.len {
			break
		}

		r := input[i]
		if r == `\n` {
			lines << cur_line.string()
			cur_line = []rune{}
			cur_width = 0
			continue
		}

		rw := visual_width_char(r)
		if cur_width + rw > content_width {
			lines << cur_line.string()
			cur_line = []rune{}
			cur_width = 0
		}

		cur_line << r
		cur_width += rw
	}

	lines << cur_line.string()
	if !found_cursor {
		cursor_row = lines.len - 1
		cursor_col = cur_width
	}

	return MultiLineInputView{
		lines:      lines
		cursor_row: cursor_row
		cursor_col: cursor_col
	}
}

pub fn (app App) get_input_content_height(content_width int) int {
	view := calculate_multiline_input_view(app.input, app.cursor_pos, content_width)
	h := view.lines.len
	if h < 1 {
		return 1
	}
	if h > max_input_visible_lines {
		return max_input_visible_lines
	}
	return h
}

// move_cursor_up moves cursor up one line, or returns false if already on top line.
pub fn (mut app App) move_cursor_up(content_width int) bool {
	view := calculate_multiline_input_view(app.input, app.cursor_pos, content_width)
	if view.cursor_row <= 0 {
		return false
	}
	target_row := view.cursor_row - 1
	target_col := view.cursor_col

	// Find the rune index corresponding to target_row and target_col
	mut cur_row := 0
	mut cur_col := 0
	for i := 0; i < app.input.len; i++ {
		r := app.input[i]
		if cur_row == target_row && cur_col >= target_col {
			app.cursor_pos = i
			return true
		}
		if r == `\n` {
			if cur_row == target_row {
				app.cursor_pos = i
				return true
			}
			cur_row++
			cur_col = 0
			continue
		}
		rw := visual_width_char(r)
		if cur_col + rw > content_width {
			if cur_row == target_row {
				app.cursor_pos = i
				return true
			}
			cur_row++
			cur_col = 0
		}
		cur_col += rw
	}
	return false
}

// move_cursor_down moves cursor down one line, or returns false if already on bottom line.
pub fn (mut app App) move_cursor_down(content_width int) bool {
	view := calculate_multiline_input_view(app.input, app.cursor_pos, content_width)
	if view.cursor_row >= view.lines.len - 1 {
		return false
	}
	target_row := view.cursor_row + 1
	target_col := view.cursor_col

	mut cur_row := 0
	mut cur_col := 0
	for i := 0; i < app.input.len; i++ {
		r := app.input[i]
		if cur_row == target_row && cur_col >= target_col {
			app.cursor_pos = i
			return true
		}
		if r == `\n` {
			if cur_row == target_row {
				app.cursor_pos = i
				return true
			}
			cur_row++
			cur_col = 0
			continue
		}
		rw := visual_width_char(r)
		if cur_col + rw > content_width {
			if cur_row == target_row {
				app.cursor_pos = i
				return true
			}
			cur_row++
			cur_col = 0
		}
		cur_col += rw
	}
	app.cursor_pos = app.input.len
	return true
}

// move_cursor_to_line_start moves to current visual line's start.
pub fn (mut app App) move_cursor_to_line_start() {
	for app.cursor_pos > 0 && app.input[app.cursor_pos - 1] != `\n` {
		app.cursor_pos--
	}
}

// move_cursor_to_line_end moves to current visual line's end.
pub fn (mut app App) move_cursor_to_line_end() {
	for app.cursor_pos < app.input.len && app.input[app.cursor_pos] != `\n` {
		app.cursor_pos++
	}
}

// === Autocomplete management ===

pub fn (mut app App) update_autocomplete() {
	text := app.input.string()
	if !text.starts_with('/') || text.contains(' ') {
		app.ac_visible = false
		app.ac_items = []AutocompleteItem{}
		return
	}

	query := text[1..]
	mut items := []AutocompleteItem{}
	for cmd in slash_commands {
		cmd_name := cmd.value[1..]
		if fuzzy_match(query, cmd_name) {
			items << cmd
		}
	}

	if items.len > 0 {
		app.ac_visible = true
		app.ac_items = items
		if app.ac_selected >= items.len {
			app.ac_selected = 0
		}
	} else {
		app.ac_visible = false
		app.ac_items = []AutocompleteItem{}
	}
}

pub fn (mut app App) autocomplete_accept() {
	if !app.ac_visible || app.ac_items.len == 0 {
		return
	}
	item := app.ac_items[app.ac_selected]
	app.input = item.value.runes()
	app.input << ` `
	app.cursor_pos = app.input.len
	app.ac_visible = false
	app.ac_items = []AutocompleteItem{}
}

// === Input editing helpers ===

pub fn (mut app App) insert_rune_at_cursor(r rune) {
	if app.cursor_pos >= app.input.len {
		app.input << r
	} else {
		app.input.insert(app.cursor_pos, r)
	}
	app.cursor_pos++
}

pub fn (mut app App) delete_rune_before_cursor() {
	if app.cursor_pos <= 0 || app.input.len == 0 {
		return
	}
	app.input.delete(app.cursor_pos - 1)
	app.cursor_pos--
}

pub fn (mut app App) delete_word_backward() {
	if app.cursor_pos == 0 {
		return
	}
	mut pos := app.cursor_pos - 1
	for pos > 0 && app.input[pos] == ` ` {
		pos--
	}
	for pos > 0 && app.input[pos - 1] != ` ` {
		pos--
	}
	mut new_input := []rune{cap: app.input.len - (app.cursor_pos - pos)}
	new_input << app.input[..pos]
	new_input << app.input[app.cursor_pos..]
	app.input = new_input
	app.cursor_pos = pos
}

pub fn (mut app App) delete_to_line_start() {
	if app.cursor_pos == 0 {
		return
	}
	app.input = app.input[app.cursor_pos..].clone()
	app.cursor_pos = 0
}

pub fn (mut app App) delete_to_line_end() {
	if app.cursor_pos >= app.input.len {
		return
	}
	app.input = app.input[..app.cursor_pos].clone()
}
