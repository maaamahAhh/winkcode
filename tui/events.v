module tui

import term.ui as termui
import time

$if windows {
	fn C.GetStdHandle(u32) voidptr
	fn C.GetNumberOfConsoleInputEvents(voidptr, &u32) bool
}

fn has_pending_console_events() bool {
	$if windows {
		h_stdin := C.GetStdHandle(u32(0xFFFFFFF6))
		mut pending := u32(0)
		if C.GetNumberOfConsoleInputEvents(h_stdin, &pending) {
			return pending > 0
		}
	}
	return false
}

fn handle_selector_event(mut app App, e &termui.Event) {
	if e.typ != .key_down {
		return
	}
	match e.code {
		.escape {
			app.close_selector()
		}
		.enter {
			app.selector.confirm()
		}
		.up {
			if app.selector.filtered.len > 0 {
				if app.selector.selected > 0 {
					app.selector.selected--
				} else {
					app.selector.selected = app.selector.filtered.len - 1
				}
			}
		}
		.down {
			if app.selector.filtered.len > 0 {
				if app.selector.selected < app.selector.filtered.len - 1 {
					app.selector.selected++
				} else {
					app.selector.selected = 0
				}
			}
		}
		.backspace {
			if app.selector.filter.len > 0 {
				app.selector.filter.delete_last()
				app.selector.update_filter(app.selector.filter.string())
			}
		}
		.space {
			app.selector.toggle()
		}
		else {
			if e.utf8.len > 0 {
				for r in e.utf8.runes() {
					if r >= 32 {
						app.selector.filter << r
					}
				}
				app.selector.update_filter(app.selector.filter.string())
			}
		}
	}
}

pub fn handle_normal_event(mut app App, e &termui.Event) {
	if e.typ != .key_down {
		return
	}

	now := time.ticks()
	delta := if app.last_key_time > 0 { now - app.last_key_time } else { i64(999999) }
	app.last_key_time = now

	if delta < 35 {
		app.burst_count++
	} else {
		app.burst_count = 0
	}

	is_ctrl := e.modifiers.has(.ctrl) || e.modifiers == .ctrl
	is_ctrl_o := (is_ctrl && e.code == .o) || e.utf8 == '\x0f'

	// Ctrl combinations
	if is_ctrl || is_ctrl_o {
		match e.code {
			.l {
				app.messages = []ChatMessage{}
				app.streaming_text = ''
				app.header_mode = .full
				app.ag.clear_conversation()
				return
			}
			.o {
				app.expand_tool_results = !app.expand_tool_results
				return
			}
			.a {
				app.cursor_pos = 0
				return
			}
			.e {
				app.cursor_pos = app.input.len
				return
			}
			.u {
				app.delete_to_line_start()
				app.update_autocomplete()
				return
			}
			.k {
				app.delete_to_line_end()
				return
			}
			.w {
				app.delete_word_backward()
				app.update_autocomplete()
				return
			}
			else {
				if is_ctrl_o {
					app.expand_tool_results = !app.expand_tool_results
					return
				}
			}
		}
	}

	match e.code {
		.escape {
			if app.is_loading {
				app.ag.client.aborted = true
				// Immediately restore input state so user can type next message
				app.is_loading = false
				app.status = ''
			} else {
				if app.input.len > 0 {
					app.input = []rune{}
					app.cursor_pos = 0
					app.update_autocomplete()
				}
			}
		}
		.c {
			if e.modifiers == .ctrl {
				app.save_session()
				exit(0)
			} else {
				if e.utf8.len > 0 {
					for r in e.utf8.runes() {
						if r >= 32 {
							app.insert_rune_at_cursor(r)
						}
					}
					app.update_autocomplete()
				}
			}
		}
		.enter {
			// Shift+Enter, Alt+Enter, or Ctrl+J inserts newline without submitting.
			// When pasting multiline text, newlines arrive in a rapid burst (< 35ms)
			// or with pending console input events. In that case, insert newline instead
			// of prematurely submitting the first line.
			is_multiline_key := e.modifiers.has(.shift) || e.modifiers.has(.alt)
			is_paste := has_pending_console_events() || (app.burst_count >= 1 && delta < 35)
			if is_multiline_key || is_paste {
				app.insert_rune_at_cursor(`\n`)
				app.update_autocomplete()
			} else {
				app.submit_input()
			}
		}
		.backspace {
			app.delete_rune_before_cursor()
			app.update_autocomplete()
		}
		.left {
			if app.cursor_pos > 0 {
				app.cursor_pos--
			}
		}
		.right {
			if app.cursor_pos < app.input.len {
				app.cursor_pos++
			}
		}
		.home {
			app.move_cursor_to_line_start()
		}
		.end {
			app.move_cursor_to_line_end()
		}
		.tab {
			app.autocomplete_accept()
		}
		.up {
			if app.ac_visible && app.ac_items.len > 0 {
				if app.ac_selected > 0 {
					app.ac_selected--
				} else {
					app.ac_selected = app.ac_items.len - 1
				}
			} else {
				// Multi-line cursor up navigation
				content_width := app.ctx.window_width - visual_width('│ > ') - visual_width('│')
				if !app.move_cursor_up(content_width) {
					// Top line reached: navigate history
					if app.history_index > 0 {
						app.history_index--
						app.input = app.input_history[app.history_index].runes()
						app.cursor_pos = app.input.len
					}
				}
			}
		}
		.down {
			if app.ac_visible && app.ac_items.len > 0 {
				if app.ac_selected < app.ac_items.len - 1 {
					app.ac_selected++
				} else {
					app.ac_selected = 0
				}
			} else {
				// Multi-line cursor down navigation
				content_width := app.ctx.window_width - visual_width('│ > ') - visual_width('│')
				if !app.move_cursor_down(content_width) {
					// Bottom line reached: navigate history
					if app.history_index < app.input_history.len {
						app.history_index++
						if app.history_index >= app.input_history.len {
							app.input = []rune{}
							app.cursor_pos = 0
						} else {
							app.input = app.input_history[app.history_index].runes()
							app.cursor_pos = app.input.len
						}
					}
				}
			}
		}
		.page_up {
			app.scroll_offset += 15
			if app.scroll_offset > app.max_scroll_offset {
				app.scroll_offset = app.max_scroll_offset
			}
		}
		.page_down {
			app.scroll_offset -= 15
			if app.scroll_offset < 0 {
				app.scroll_offset = 0
			}
		}
		else {
			if e.utf8.len > 0 {
				clean_utf8 := e.utf8.replace('\r\n', '\n').replace('\r', '\n')
				for r in clean_utf8.runes() {
					// Support paste containing newlines and normalize tabs to 2 spaces
					if r == `\t` {
						app.insert_rune_at_cursor(` `)
						app.insert_rune_at_cursor(` `)
					} else if r >= 32 || r == `\n` {
						app.insert_rune_at_cursor(r)
					}
				}
				app.update_autocomplete()
			}
		}
	}
}

fn on_event(e &termui.Event, x voidptr) {
	mut app := unsafe { &App(x) }

	// Handle mouse scroll in any mode
	if e.typ == .mouse_scroll {
		match e.direction {
			.up {
				app.scroll_offset -= 3
				if app.scroll_offset < 0 {
					app.scroll_offset = 0
				}
			}
			.down {
				app.scroll_offset += 3
				if app.scroll_offset > app.max_scroll_offset {
					app.scroll_offset = app.max_scroll_offset
				}
			}
			else {}
		}
		return
	}

	if e.typ != .key_down {
		return
	}
	match app.mode {
		.selector {
			handle_selector_event(mut app, e)
		}
		.normal {
			handle_normal_event(mut app, e)
		}
	}
}
