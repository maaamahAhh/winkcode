module tui

const slash_commands = [
	AutocompleteItem{'/model', 'show/switch model'},
	AutocompleteItem{'/effort', 'show/set effort'},
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

pub fn get_input_view(input []rune, cursor_pos int, content_width int) (string, int) {
	if content_width <= 0 {
		return '', 0
	}

	mut cursor_col := 0
	for i := 0; i < cursor_pos && i < input.len; i++ {
		cursor_col += visual_width_char(input[i])
	}

	mut total_width := 0
	for r in input {
		total_width += visual_width_char(r)
	}

	if total_width <= content_width {
		return input.string(), cursor_col
	}

	mut scroll := 0
	if cursor_col >= content_width - 2 {
		scroll = cursor_col - content_width + 3
		if scroll < 0 {
			scroll = 0
		}
	}

	mut col := 0
	mut start_idx := 0
	for i := 0; i < input.len; i++ {
		w := visual_width_char(input[i])
		if col >= scroll {
			start_idx = i
			break
		}
		col += w
	}

	mut visible := []rune{}
	mut width := 0
	for i := start_idx; i < input.len; i++ {
		w := visual_width_char(input[i])
		if width + w > content_width {
			break
		}
		visible << input[i]
		width += w
	}

	return visible.string(), cursor_col - scroll
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
		mut new_input := []rune{}
		for i := 0; i < app.cursor_pos; i++ {
			new_input << app.input[i]
		}
		new_input << r
		for i := app.cursor_pos; i < app.input.len; i++ {
			new_input << app.input[i]
		}
		app.input = new_input
	}
	app.cursor_pos++
}

pub fn (mut app App) delete_rune_before_cursor() {
	if app.cursor_pos <= 0 || app.input.len == 0 {
		return
	}
	mut new_input := []rune{}
	for i := 0; i < app.input.len; i++ {
		if i != app.cursor_pos - 1 {
			new_input << app.input[i]
		}
	}
	app.input = new_input
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
	mut new_input := []rune{}
	for i := 0; i < pos; i++ {
		new_input << app.input[i]
	}
	for i := app.cursor_pos; i < app.input.len; i++ {
		new_input << app.input[i]
	}
	app.input = new_input
	app.cursor_pos = pos
}

pub fn (mut app App) delete_to_line_start() {
	if app.cursor_pos == 0 {
		return
	}
	mut new_input := []rune{}
	for i := app.cursor_pos; i < app.input.len; i++ {
		new_input << app.input[i]
	}
	app.input = new_input
	app.cursor_pos = 0
}

pub fn (mut app App) delete_to_line_end() {
	if app.cursor_pos >= app.input.len {
		return
	}
	mut new_input := []rune{}
	for i := 0; i < app.cursor_pos; i++ {
		new_input << app.input[i]
	}
	app.input = new_input
}

// === Selector management ===

pub fn (mut app App) open_model_selector() {
	names := app.ag.get_model_names()
	current := app.ag.get_model()
	mut items := []SelectorItem{}
	for name in names {
		provider := app.ag.get_model_provider(name)
		items << SelectorItem{
			value: name
			label: name
			badge: provider
			is_current: name == current
		}
	}
	app.selector.open(items, 'Select Model', fn [mut app] (item SelectorItem) {
		app.ag.set_model(item.value) or {
			app.push_message('error', err.str())
			return
		}
		app.push_message('system', 'Model: ${app.ag.get_model()}')
	}, fn () {})
	app.mode = .selector
}

pub fn (mut app App) open_effort_selector() {
	current := app.ag.get_effort()
	levels := ['low', 'medium', 'high', 'max']
	mut items := []SelectorItem{}
	for level in levels {
		items << SelectorItem{
			value: level
			label: level
			badge: ''
			is_current: level == current
		}
	}
	app.selector.open(items, 'Select Effort', fn [mut app] (item SelectorItem) {
		app.ag.set_effort(item.value) or {
			app.push_message('error', err.str())
			return
		}
		app.push_message('system', 'Effort: ${app.ag.get_effort()}')
	}, fn () {})
	app.mode = .selector
}

pub fn (mut app App) open_mcp_selector() {
	mut items := []SelectorItem{}
	for mut server in app.ag.mcp_manager.servers {
		status := if server.disabled { 'disabled' } else if server.is_connected { 'connected' } else { 'idle' }
		items << SelectorItem{
			value: server.name
			label: server.name
			badge: status
			is_current: false
		}
	}
	app.selector.open(items, 'Manage MCP', fn [mut app] (item SelectorItem) {
		// Enter on MCP item opens /mcp toggle command
		app.handle_command('/mcp toggle ${item.value}')
		app.close_selector()
	}, fn [mut app] () {
		// Space toggles the selected MCP server
		if app.selector.filtered.len == 0 {
			return
		}
		item := app.selector.filtered[app.selector.selected]
		app.handle_command('/mcp toggle ${item.value}')
	})
	app.mode = .selector
}

pub fn (mut app App) close_selector() {
	app.selector.close()
	app.mode = .normal
}

pub fn (mut app App) update_selector_filter() {
	app.selector.update_filter(app.selector.filter.string())
}

pub fn (mut app App) selector_confirm() {
	app.selector.confirm()
}
