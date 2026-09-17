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

	// Header
	mut row := draw_header(mut app, width, height, bottom_area_height)

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
	mut start_doc_idx := visible.start_index

	mut indent_rows := 0
	if visible.indicator.len > 0 {
		apply_color(mut app.ctx, 'dim')
		app.ctx.draw_text(1, row, truncate_by_width(visible.indicator, chat_width))
		app.ctx.reset()
		row++
		indent_rows = 1
		if visible_lines.len > chat_height - 1 {
			visible_lines = visible_lines[1..].clone()
			start_doc_idx++
		}
	}

	app.chat_start_row = row - indent_rows
	app.chat_end_row = chat_end
	app.chat_indent_rows = indent_rows
	app.chat_width = chat_width
	app.visible_start_doc_idx = start_doc_idx
	app.all_chat_lines = all_lines.clone()
	app.visible_chat_lines = visible_lines.clone()

	norm_sel := app.selection.normalized()

	for i, line in visible_lines {
		if row >= chat_end {
			break
		}
		doc_idx := start_doc_idx + i
		draw_chat_line(mut app, line, row, doc_idx, chat_width, norm_sel)
		row++
	}

	draw_bottom_area(mut app, width, chat_end)
	draw_footer(mut app, width, height)
	position_cursor(mut app, width, chat_end)

	app.ctx.flush()
}

fn draw_chat_line(mut app App, line RenderLine, row int, doc_idx int, chat_width int, norm ?NormalizedSelection) {
	col_range := if ns := norm {
		ns.col_range_for_line(doc_idx, chat_width)
	} else {
		none
	}

	if col_range == none {
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
		return
	}

	sel_start := col_range.start
	sel_end := col_range.end
	mut col := 1

	if line.segs.len > 0 {
		for seg in line.segs {
			seg_color := seg.color
			for r in seg.text.runes() {
				vw := visual_width_char(r)
				if col + vw - 1 > chat_width {
					break
				}
				is_sel := (col + vw - 1 >= sel_start) && (col <= sel_end)
				if is_sel {
					apply_selection_style(mut app.ctx)
					app.ctx.draw_text(col, row, r.str())
					app.ctx.reset()
				} else {
					apply_color(mut app.ctx, seg_color)
					app.ctx.draw_text(col, row, r.str())
					app.ctx.reset()
				}
				col += vw
			}
		}
	} else {
		line_color := line.color
		for r in line.text.runes() {
			vw := visual_width_char(r)
			if col + vw - 1 > chat_width {
				break
			}
			is_sel := (col + vw - 1 >= sel_start) && (col <= sel_end)
			if is_sel {
				apply_selection_style(mut app.ctx)
				app.ctx.draw_text(col, row, r.str())
				app.ctx.reset()
			} else {
				apply_color(mut app.ctx, line_color)
				app.ctx.draw_text(col, row, r.str())
				app.ctx.reset()
			}
			col += vw
		}
	}
}
