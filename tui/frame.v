module tui

// on_frame coordinates the TUI rendering loop.
pub fn on_frame(x voidptr) {
	mut app := unsafe { &App(x) }
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	app.ctx.clear()
	width := app.ctx.window_width
	height := app.ctx.window_height

	// Update spinner frame
	app.spinner_frame = (app.spinner_frame + 1) % spinner_frames.len

	// Header (always visible)
	mut row := draw_header(mut app, width)

	// Calculate layout
	footer_height := 1
	content_width := width - visual_width('│ > ') - visual_width('│')
	input_content_h := app.get_input_content_height(content_width)
	input_box_height := input_content_h + 2

	mut bottom_area_height := input_box_height + footer_height

	if app.mode != .normal {
		mut max_vis := selector_max_visible
		if max_vis > app.selector.filtered.len {
			max_vis = app.selector.filtered.len
		}
		selector_height := 1 + 1 + max_vis + 1 + 1
		bottom_area_height = selector_height + footer_height
	} else {
		if app.ac_visible && app.ac_items.len > 0 {
			mut ac_count := app.ac_items.len
			if ac_count > 5 {
				ac_count = 5
			}
			bottom_area_height = input_box_height + footer_height + ac_count
		}
		if app.is_loading && app.streaming_text.len == 0 {
			bottom_area_height += 1
		}
	}

	mut chat_end := height - bottom_area_height
	if chat_end < row {
		chat_end = row
	}

	// Message area
	chat_width := width - 2
	mut chat_height := chat_end - row
	if chat_height < 1 {
		chat_height = 1
	}

	all_lines := build_chat_lines(app.messages, app.streaming_text, app.streaming_thinking,
		app.streaming_tool_name, app.streaming_tool_args, app.expand_tool_results, app.is_loading,
		app.status, chat_width, 10000, app.spinner_frame)
	max_offset := if all_lines.len > chat_height { all_lines.len - chat_height } else { 0 }
	app.max_scroll_offset = max_offset
	if app.scroll_offset > max_offset {
		app.scroll_offset = max_offset
	}
	if app.scroll_offset < 0 {
		app.scroll_offset = 0
	}
	visible := calculate_visible_window(all_lines, chat_height, app.scroll_offset)
	mut visible_lines := visible.lines.clone()

	if visible.indicator.len > 0 {
		apply_color(mut app.ctx, 'dim')
		app.ctx.draw_text(1, row, truncate_by_width(visible.indicator, chat_width))
		app.ctx.reset()
		row++
		if visible_lines.len > chat_height - 1 {
			visible_lines = visible_lines[1..].clone()
		}
	}

	for line in visible_lines {
		if row >= chat_end {
			break
		}
		if line.segs.len > 0 {
			mut col := 1
			for seg in line.segs {
				apply_color(mut app.ctx, seg.color)
				app.ctx.draw_text(col, row, truncate_by_width(seg.text, chat_width - col + 1))
				app.ctx.reset()
				col += visual_width(seg.text)
			}
		} else {
			apply_color(mut app.ctx, line.color)
			app.ctx.draw_text(1, row, truncate_by_width(line.text, chat_width))
			app.ctx.reset()
		}
		row++
	}

	draw_bottom_area(mut app, width, chat_end)
	draw_footer(mut app, width, height)
	position_cursor(mut app, width, chat_end)

	app.ctx.flush()
}
