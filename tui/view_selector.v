module tui

// draw_selector renders the selector dropdown / modal.
fn draw_selector(mut app App, width int, y_top int) int {
	title := app.selector.title

	total_items := app.selector.filtered.len
	mut max_vis := selector_max_visible
	if total_items < max_vis {
		max_vis = total_items
	}
	if max_vis < 1 {
		max_vis = 1
	}

	// Scroll to keep selected item visible
	mut scroll_start := 0
	if app.selector.selected >= max_vis / 2 && total_items > max_vis {
		scroll_start = app.selector.selected - max_vis / 2
		if scroll_start + max_vis > total_items {
			scroll_start = total_items - max_vis
		}
	}
	if scroll_start < 0 {
		scroll_start = 0
	}

	mut vis_end := scroll_start + max_vis
	if vis_end > total_items {
		vis_end = total_items
	}

	selector_height := 1 + 1 + max_vis + 1 + 1

	// Top border with title
	inner_width := width - 2
	mut filler_width := inner_width - visual_width(title)
	if filler_width < 0 {
		filler_width = 0
	}
	apply_color(mut app.ctx, 'border_focus')
	top_line := '┌${title}${'─'.repeat(filler_width)}┐'
	app.ctx.draw_text(1, y_top, truncate_by_width(top_line, width))
	app.ctx.reset()

	// Search line
	search_y := y_top + 1
	search_content_width := width - visual_width('│ > ') - visual_width('│')
	search_visible := tail_by_width(app.selector.filter.string(), search_content_width)

	apply_color(mut app.ctx, 'border_focus')
	app.ctx.draw_text(1, search_y, '│ > ')
	app.ctx.reset()

	apply_color(mut app.ctx, 'cyan')
	app.ctx.draw_text(1 + visual_width('│ > '), search_y, search_visible)
	app.ctx.reset()

	pad_start := 1 + visual_width('│ > ') + visual_width(search_visible)
	pad_width := width - visual_width('│') - visual_width('│ > ') - visual_width(search_visible)
	if pad_width > 0 {
		app.ctx.draw_text(pad_start, search_y, ' '.repeat(pad_width))
	}
	apply_color(mut app.ctx, 'border_focus')
	app.ctx.draw_text(width - visual_width('│') + 1, search_y, '│')
	app.ctx.reset()

	// Item lines
	mut item_row := search_y + 1
	for i := scroll_start; i < vis_end; i++ {
		item := app.selector.filtered[i]
		is_selected := i == app.selector.selected

		mut display := if is_selected { '→ ' } else { '  ' }
		display += item.label

		mut suffix := ''
		if item.badge.len > 0 {
			suffix += ' [' + item.badge + ']'
		}
		if item.is_current {
			suffix += ' ✓'
		}

		item_content_width := width - visual_width('│') - visual_width('│')
		display_truncated := truncate_by_width(display, item_content_width)
		suffix_truncated := truncate_by_width(suffix,
			item_content_width - visual_width(display_truncated))

		apply_color(mut app.ctx, 'border_focus')
		app.ctx.draw_text(1, item_row, '│')
		app.ctx.reset()

		if is_selected {
			apply_color(mut app.ctx, 'cyan')
		} else {
			apply_color(mut app.ctx, 'white')
		}
		app.ctx.draw_text(1 + visual_width('│'), item_row, display_truncated)
		app.ctx.reset()

		// Pad and draw suffix
		display_end := 1 + visual_width('│') + visual_width(display_truncated)
		suffix_start := width - visual_width('│') - visual_width(suffix_truncated)
		pad_w := suffix_start - display_end
		if pad_w > 0 {
			app.ctx.draw_text(display_end, item_row, ' '.repeat(pad_w))
		}

		apply_color(mut app.ctx, 'dim')
		app.ctx.draw_text(suffix_start, item_row, suffix_truncated)
		app.ctx.reset()

		apply_color(mut app.ctx, 'border_focus')
		app.ctx.draw_text(width - visual_width('│') + 1, item_row, '│')
		app.ctx.reset()

		item_row++
	}

	// Fill remaining item rows
	for i := vis_end - scroll_start; i < max_vis; i++ {
		apply_color(mut app.ctx, 'border_focus')
		app.ctx.draw_text(1, item_row, '│')
		app.ctx.draw_text(width - visual_width('│') + 1, item_row, '│')
		app.ctx.reset()
		item_row++
	}

	// Hints line
	hints_y := item_row
	mut hints := '  ↑↓ navigate  Enter select  Esc cancel'
	if total_items > max_vis {
		hints += '  (${app.selector.selected + 1}/${total_items})'
	}
	apply_color(mut app.ctx, 'border_focus')
	app.ctx.draw_text(1, hints_y, '│')
	app.ctx.reset()
	apply_color(mut app.ctx, 'dim')
	hints_truncated := truncate_by_width(hints, width - visual_width('│') - visual_width('│'))
	app.ctx.draw_text(1 + visual_width('│'), hints_y, hints_truncated)
	app.ctx.reset()
	hints_end := 1 + visual_width('│') + visual_width(hints_truncated)
	pad_w := width - visual_width('│') - visual_width('│') - visual_width(hints_truncated)
	if pad_w > 0 {
		app.ctx.draw_text(hints_end, hints_y, ' '.repeat(pad_w))
	}
	apply_color(mut app.ctx, 'border_focus')
	app.ctx.draw_text(width - visual_width('│') + 1, hints_y, '│')
	app.ctx.reset()

	// Bottom border
	bottom_y := hints_y + 1
	apply_color(mut app.ctx, 'border_focus')
	bottom_border := '└' + '─'.repeat(width - 2) + '┘'
	app.ctx.draw_text(1, bottom_y, truncate_by_width(bottom_border, width))
	app.ctx.reset()

	return selector_height
}
