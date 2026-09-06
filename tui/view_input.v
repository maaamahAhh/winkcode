module tui

// draw_input_box renders the elastic multiline input prompt with border.
fn draw_input_box(mut app App, width int, y_top int) {
	border_color := if app.is_loading { 'border_focus' } else { 'border' }

	// Top border
	apply_color(mut app.ctx, border_color)
	top_border := '┌' + '─'.repeat(width - 2) + '┐'
	app.ctx.draw_text(1, y_top, truncate_by_width(top_border, width))
	app.ctx.reset()

	input_prefix_first := '│ > '
	input_prefix_sub := '│ · '
	input_suffix := '│'
	content_width := width - visual_width(input_prefix_first) - visual_width(input_suffix)

	view := calculate_multiline_input_view(app.input, app.cursor_pos, content_width)
	visible_count := if view.lines.len > max_input_visible_lines {
		max_input_visible_lines
	} else {
		view.lines.len
	}

	// Calculate scroll window inside input if exceeding max_input_visible_lines
	mut start_line := 0
	if view.cursor_row >= visible_count {
		start_line = view.cursor_row - visible_count + 1
	}

	for row_idx := 0; row_idx < visible_count; row_idx++ {
		actual_idx := start_line + row_idx
		line_text := if actual_idx < view.lines.len { view.lines[actual_idx] } else { '' }
		current_y := y_top + 1 + row_idx
		prefix := if actual_idx == 0 { input_prefix_first } else { input_prefix_sub }

		apply_color(mut app.ctx, border_color)
		app.ctx.draw_text(1, current_y, prefix)
		app.ctx.reset()

		apply_color(mut app.ctx, 'green')
		app.ctx.draw_text(1 + visual_width(prefix), current_y, line_text)
		app.ctx.reset()

		pad_start := 1 + visual_width(prefix) + visual_width(line_text)
		pad_width := width - visual_width(input_suffix) - visual_width(prefix) -
			visual_width(line_text)
		if pad_width > 0 {
			app.ctx.draw_text(pad_start, current_y, ' '.repeat(pad_width))
		}

		apply_color(mut app.ctx, border_color)
		app.ctx.draw_text(width - visual_width(input_suffix) + 1, current_y, input_suffix)
		app.ctx.reset()
	}

	// Bottom border
	bottom_y := y_top + 1 + visible_count
	apply_color(mut app.ctx, border_color)
	bottom_border := '└' + '─'.repeat(width - 2) + '┘'
	app.ctx.draw_text(1, bottom_y, truncate_by_width(bottom_border, width))
	app.ctx.reset()
}

// draw_autocomplete renders autocomplete suggestions above the input box.
fn draw_autocomplete(mut app App, width int, y_top int) {
	mut row := y_top
	mut count := app.ac_items.len
	if count > 5 {
		count = 5
	}

	for i := 0; i < count; i++ {
		if row < 1 {
			break
		}
		item := app.ac_items[i]
		is_selected := i == app.ac_selected

		mut display := '  '
		display += item.value
		display += '  '
		display += item.description

		if is_selected {
			apply_color(mut app.ctx, 'accent')
			app.ctx.draw_text(1, row, truncate_by_width(display, width))
			app.ctx.reset()
		} else {
			apply_color(mut app.ctx, 'dim')
			app.ctx.draw_text(1, row, truncate_by_width(display, width))
			app.ctx.reset()
		}
		row++
	}
}

// position_cursor positions the terminal cursor based on app mode and input state.
fn position_cursor(mut app App, width int, chat_end int) {
	app.ctx.show_cursor()
	if app.mode != .normal {
		// Cursor in selector filter input
		filter_visible := tail_by_width(app.selector.filter.string(), width -
			visual_width('│ > ') - visual_width('│'))
		filter_cursor_x := 1 + visual_width('│ > ') + visual_width(filter_visible)
		app.ctx.set_cursor_position(filter_cursor_x, chat_end + 1)
	} else {
		// Cursor in multiline input
		input_prefix_first := '│ > '
		input_prefix_sub := '│ · '
		content_width := width - visual_width(input_prefix_first) - visual_width('│')
		view := calculate_multiline_input_view(app.input, app.cursor_pos, content_width)

		visible_count := if view.lines.len > max_input_visible_lines {
			max_input_visible_lines
		} else {
			view.lines.len
		}

		mut start_line := 0
		if view.cursor_row >= visible_count {
			start_line = view.cursor_row - visible_count + 1
		}
		visible_cursor_row := view.cursor_row - start_line

		mut input_y := chat_end
		if app.is_loading && app.streaming_text.len == 0 {
			input_y += 1
		}
		if app.ac_visible && app.ac_items.len > 0 {
			mut ac_h := app.ac_items.len
			if ac_h > 5 {
				ac_h = 5
			}
			input_y += ac_h
		}

		prefix := if view.cursor_row == 0 { input_prefix_first } else { input_prefix_sub }
		cursor_x := 1 + visual_width(prefix) + view.cursor_col
		cursor_y := input_y + 1 + visible_cursor_row
		app.ctx.set_cursor_position(cursor_x, cursor_y)
	}
}

// draw_bottom_area renders either the selector or the input + autocomplete area.
fn draw_bottom_area(mut app App, width int, y int) {
	if app.mode != .normal {
		draw_selector(mut app, width, y)
	} else {
		mut input_y := y
		if app.is_loading && app.streaming_text.len == 0 {
			draw_loading_indicator(mut app, width, input_y)
			input_y += 1
		}
		if app.ac_visible && app.ac_items.len > 0 {
			mut ac_count := app.ac_items.len
			if ac_count > 5 {
				ac_count = 5
			}
			draw_autocomplete(mut app, width, input_y)
			input_y += ac_count
		}
		draw_input_box(mut app, width, input_y)
	}
}
