module tui

import term.ui as termui
import time
import os
import agent
import llm
import session
import compact

const max_messages = 200
const frame_rate = 24

// Spinner frames (Braille dots animation, same as pi-mono)
const spinner_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

// ASCII logo
const logo_lines = [
	' ██╗    ██╗ ██╗ ███╗   ██╗ ██╗  ██╗      ██████╗  ██████╗  ██████╗  ███████╗',
	' ██║    ██║ ██║ ████╗  ██║ ██║ ██╔╝     ██╔════╝ ██╔═══██╗ ██╔══██╗ ██╔════╝',
	' ██║ █╗ ██║ ██║ ██╔██╗ ██║ █████╔╝      ██║      ██║   ██║ ██║  ██║ █████╗  ',
	' ██║███╗██║ ██║ ██║╚██╗██║ ██╔═██╗      ██║      ██║   ██║ ██║  ██║ ██╔══╝  ',
	' ╚███╔███╔╝ ██║ ██║ ╚████║ ██║  ██╗     ╚██████╗ ╚██████╔╝ ██████╔╝ ███████╗',
	'  ╚══╝╚══╝  ╚═╝ ╚═╝  ╚═══╝ ╚═╝  ╚═╝      ╚═════╝  ╚═════╝  ╚═════╝  ╚══════╝',
]

// === Types ===

pub struct ChatMessage {
pub:
	role        string
	text        string
	thinking    string
	time        string
	tool_status string // '', 'pending', 'success', 'error'
}

struct RenderLine {
	text  string
	color string
}

enum AppMode {
	normal
	selector
}

enum HeaderMode {
	full
	compact
}

@[heap]
pub struct App {
pub mut:
	ctx              &termui.Context = unsafe { nil }
	ag               &agent.Agent = unsafe { nil }
	messages         []ChatMessage
	input            []rune
	cursor_pos       int
	streaming_text   string
	streaming_thinking string
	status           string
	is_loading       bool
	loading_start    i64
	version          string
	header_mode      HeaderMode = .full
	mode             AppMode = .normal
	spinner_frame    int
	// Selector state
	selector         SelectorState
	// Autocomplete state
	ac_items    []AutocompleteItem
	ac_selected int
	ac_visible  bool
	// Scroll state
	scroll_offset int // 0 = bottom (latest), >0 = scrolled up N lines
	// Input history
	input_history []string
	history_index  int
	// Tool timing state
	tool_start_times map[string]i64
	// Session state
	session_id   string
	session_path string
	// Debounce session saves
	session_dirty   bool
	last_save_time  i64
}

// === Message management ===

pub fn (mut app App) push_message(role string, text string) {
	app.messages << ChatMessage{role: role, text: text, time: now_formatted()}
	if app.messages.len > max_messages {
		app.messages = app.messages[app.messages.len - max_messages..]
	}
	// Switch to compact header after first message
	if app.header_mode == .full {
		app.header_mode = .compact
	}
	// Save session
	app.save_session()
}

pub fn (mut app App) push_assistant_message(text string, thinking string) {
	app.messages << ChatMessage{role: 'assistant', text: text, thinking: thinking, time: now_formatted()}
	if app.messages.len > max_messages {
		app.messages = app.messages[app.messages.len - max_messages..]
	}
	if app.header_mode == .full {
		app.header_mode = .compact
	}
	// Save session
	app.save_session()
}

pub fn (mut app App) push_tool_message(name string, status string, result_preview string, is_error bool) {
	tool_status := if is_error { 'error' } else if status == 'done' { 'success' } else { 'pending' }
	app.messages << ChatMessage{role: 'tool_call', text: name, time: now_formatted(), tool_status: tool_status}
	if result_preview.len > 0 {
		result_role := if is_error { 'tool_error' } else { 'tool_result' }
		app.messages << ChatMessage{role: result_role, text: result_preview, time: now_formatted()}
	}
	if app.messages.len > max_messages {
		app.messages = app.messages[app.messages.len - max_messages..]
	}
	if app.header_mode == .full {
		app.header_mode = .compact
	}
	// Save session
	app.save_session()
}

fn now_formatted() string {
	return time.now().custom_format('HH:mm:ss')
}

fn (mut app App) save_session() {
	now := time.ticks()
	if app.last_save_time > 0 && (now - app.last_save_time) < 500 {
		app.session_dirty = true
		return
	}
	app.session_dirty = false
	app.last_save_time = now
	app.do_save_session()
}

fn (mut app App) flush_session() {
	if !app.session_dirty {
		return
	}
	app.session_dirty = false
	app.do_save_session()
}

fn (mut app App) do_save_session() {
	if app.session_path.len == 0 {
		// Create new session
		model := app.ag.get_model()
		provider := app.ag.config.get_model_provider(model)
		mut s := session.new_session(model, provider)
		s.session_path = session.session_file_path(s.header)
		app.session_id = s.header.id
		app.session_path = s.session_path
		app.session_append_all(mut s)
	} else {
		// Try to load existing session; on failure, reset and create new
		mut s := session.load_session(app.session_path) or {
			app.session_path = ''
			app.session_id = ''
			app.do_save_session()
			return
		}
		app.session_rewrite(mut s)
	}
}

fn (mut app App) session_rewrite(mut s session.Session) {
	// Rebuild session from current messages
	s.messages = []session.SessionMessage{}
	for msg in app.messages {
		s.messages << session.SessionMessage{
			role: msg.role
			text: msg.text
			timestamp: msg.time
			tool_status: msg.tool_status
		}
	}
	s.save() or {}
	app.session_id = s.header.id
	app.session_path = s.session_path
}

fn (mut app App) session_append_all(mut s session.Session) {
	// Append all messages to new session file
	s.save() or {}
	app.session_id = s.header.id
	app.session_path = s.session_path
}

fn get_cwd_short() string {
	cwd := os.getwd()
	home := os.home_dir()
	if home.len > 0 && cwd.starts_with(home) {
		return '~' + cwd[home.len..]
	}
	return cwd
}

// === Query execution ===

pub fn (mut app App) submit_input() {
	app.flush_session()
	if app.is_loading {
		return
	}
	prompt := app.input.string().trim_space()
	if prompt.len == 0 {
		return
	}
	// Save to input history
	app.input_history << prompt
	app.history_index = app.input_history.len
	app.input = []rune{}
	app.cursor_pos = 0
	app.ac_visible = false

	if prompt.starts_with('/') {
		app.handle_command(prompt)
		return
	}

	app.push_message('user', prompt)
	app.streaming_text = ''
	app.status = 'Thinking...'
	app.is_loading = true
	app.loading_start = time.ticks()
	app.scroll_offset = 0
	go app.run_query(prompt)
}

fn (mut app App) handle_command(cmd string) {
	parts := cmd.split(' ')
	match parts[0] {
		'/model' { app.cmd_model(parts) }
		'/effort' { app.cmd_effort(parts) }
		'/clear' { app.cmd_clear() }
		'/compact' { app.cmd_compact() }
		'/help' { app.cmd_help() }
		'/mcp' { app.cmd_mcp(parts) }
		else {
			app.push_message('error', 'Unknown command: ${cmd}')
		}
	}
}

fn (mut app App) cmd_model(parts []string) {
	if parts.len > 1 && parts[1].len > 0 {
		name := parts[1]
		app.ag.set_model(name) or {
			app.push_message('error', err.str())
			return
		}
		app.push_message('system', 'Model: ${app.ag.get_model()}')
	} else {
		app.open_model_selector()
	}
}

fn (mut app App) cmd_effort(parts []string) {
	if parts.len > 1 && parts[1].len > 0 {
		level := parts[1]
		app.ag.set_effort(level) or {
			app.push_message('error', err.str())
			return
		}
		app.push_message('system', 'Effort: ${app.ag.get_effort()}')
	} else {
		app.open_effort_selector()
	}
}

fn (mut app App) cmd_clear() {
	app.messages = []ChatMessage{}
	app.streaming_text = ''
	app.streaming_thinking = ''
	app.header_mode = .full
	app.ag.clear_conversation()
}

fn (mut app App) cmd_compact() {
	if !compact.should_compact(app.ag.client.messages) {
		app.push_message('system', 'Context is too small to compact.')
		return
	}
	compact.compact(mut app.ag.client) or {
		app.push_message('error', 'Compaction failed: ${err.str()}')
		return
	}
	app.push_message('system', 'Context compacted.')
}

fn (mut app App) cmd_help() {
	msg := 'Commands:\n  /model [name] - show/switch model\n  /effort [level] - show/set effort\n  /help - show this help\n  /clear - clear conversation\n  /compact - compact context\n  /mcp list - list MCP servers\n  /mcp toggle <name> - enable/disable MCP server\n  ctrl+l - clear conversation\n  esc - interrupt/quit'
	app.push_message('system', msg)
}

fn (mut app App) cmd_mcp(parts []string) {
	if parts.len > 1 && parts[1] == 'toggle' && parts.len > 2 {
		name := parts[2]
		mut found := false
		for mut server in app.ag.mcp_manager.servers {
			if server.name == name {
				found = true
				server.disabled = !server.disabled
				if server.disabled && server.is_connected {
					app.ag.mcp_manager.stop_server(name)
				}
				status := if server.disabled { 'disabled' } else { 'enabled' }
				app.push_message('system', 'MCP server ${name} ${status}.')
				break
			}
		}
		if !found {
			app.push_message('error', 'MCP server not found: ${name}')
		}
	} else {
		app.open_mcp_selector()
	}
}

fn (mut app App) run_query(prompt string) {
	cb := agent.AgentCallbacks{
		on_thinking: fn [mut app] (text string) {
			if !app.ag.client.aborted {
				app.streaming_thinking += text
			}
		}
		on_text: fn [mut app] (text string) {
			if !app.ag.client.aborted {
				app.streaming_text += text
			}
		}
		on_tool_call: fn [mut app] (name string, status string) {
			if app.streaming_text.len > 0 || app.streaming_thinking.len > 0 {
				app.push_assistant_message(app.streaming_text, app.streaming_thinking)
				app.streaming_text = ''
				app.streaming_thinking = ''
			}
			// Track tool start time on "calling"
			if status.starts_with('calling') {
				app.tool_start_times[name] = time.now().unix_nano()
			}
			// Update existing tool_call message or create new one
			if app.messages.len > 0 {
				last_idx := app.messages.len - 1
				last := app.messages[last_idx]
				if last.role == 'tool_call' && last.text == name {
					app.status = status
					return
				}
			}
			app.messages << ChatMessage{role: 'tool_call', text: name, time: now_formatted(), tool_status: 'pending'}
			if app.header_mode == .full {
				app.header_mode = .compact
			}
			app.status = status
		}
		on_tool_result: fn [mut app] (name string, preview string, is_error bool) {
			tool_status := if is_error { 'error' } else { 'success' }
			// Calculate duration
			mut duration_str := ''
			if name in app.tool_start_times {
				start_ns := app.tool_start_times[name]
				elapsed_ns := time.now().unix_nano() - start_ns
				elapsed_ms := elapsed_ns / 1_000_000
				if elapsed_ms < 1000 {
					duration_str = ' (${elapsed_ms}ms)'
				} else {
					duration_str = ' (${f32(elapsed_ms) / 1000.0:.1f}s)'
				}
				app.tool_start_times.delete(name)
			}
			// Update last tool_call message status by replacing the struct
			if app.messages.len > 0 {
				last_idx := app.messages.len - 1
				last := app.messages[last_idx]
				if last.role == 'tool_call' && last.text == name {
					app.messages[last_idx] = ChatMessage{role: last.role, text: last.text + duration_str, time: last.time, tool_status: tool_status}
				}
			}
			if preview.len > 0 {
				result_role := if is_error { 'tool_error' } else { 'tool_result' }
				app.push_message(result_role, preview)
			}
		}
		on_complete: fn [mut app] () {
			if app.streaming_text.len > 0 || app.streaming_thinking.len > 0 {
				app.push_assistant_message(app.streaming_text, app.streaming_thinking)
				app.streaming_text = ''
				app.streaming_thinking = ''
			}
			app.status = ''
			app.is_loading = false
			app.flush_session()
		}
		on_error: fn [mut app] (msg string) {
			if app.streaming_text.len > 0 || app.streaming_thinking.len > 0 {
				app.push_assistant_message(app.streaming_text, app.streaming_thinking)
				app.streaming_text = ''
				app.streaming_thinking = ''
			}
			app.push_message('error', msg)
			app.status = ''
			app.is_loading = false
			app.flush_session()
		}
	}
	app.ag.run(prompt, cb)
}

// === Build render lines from messages ===

pub fn build_chat_lines(messages []ChatMessage, streaming_text string, streaming_thinking string, is_loading bool, status string, width int, max_lines int) []RenderLine {
	mut lines := []RenderLine{}
	for item in messages {
		prefix := message_prefix(item.role, item.tool_status)
		prefix_color := message_prefix_color(item.role, item.tool_status)

		// Tool call: compact single line (no separate body)
		if item.role == 'tool_call' {
			lines << RenderLine{text: '${prefix} ${item.text}', color: prefix_color}
			continue
		}

		// Tool result/error: indented with │ under the tool call
		if item.role == 'tool_result' || item.role == 'tool_error' {
			text_color := message_text_color(item.role)
			for wrapped in wrap_text(item.text, width - 4, max_lines) {
				lines << RenderLine{text: '  │ ${wrapped}', color: text_color}
			}
			continue
		}

		// User / assistant / system / error messages
		lines << RenderLine{text: '${prefix} ${item.time}', color: prefix_color}
		// Render thinking block for assistant messages (before text)
		if item.role == 'assistant' && item.thinking.len > 0 {
			for tl in render_thinking(item.thinking, width - 2) {
				lines << tl
			}
		}
		// Use markdown rendering for assistant messages, plain for others
		if item.role == 'assistant' {
			md_lines := render_markdown(item.text, width - 2)
			for ml in md_lines {
				lines << RenderLine{text: '  ${ml.text}', color: ml.color}
			}
		} else {
			text_color := message_text_color(item.role)
			for wrapped in wrap_text(item.text, width - 2, max_lines) {
				lines << RenderLine{text: '  ${wrapped}', color: text_color}
			}
		}
		lines << RenderLine{text: '', color: 'white'}
	}
	if streaming_thinking.len > 0 || streaming_text.len > 0 {
		lines << RenderLine{text: '✦ ${now_formatted()}', color: 'cyan'}
		if streaming_thinking.len > 0 {
			for tl in render_thinking(streaming_thinking, width - 2) {
				lines << tl
			}
		}
		if streaming_text.len > 0 {
			md_lines := render_markdown(streaming_text, width - 2)
			for ml in md_lines {
				lines << RenderLine{text: '  ${ml.text}', color: ml.color}
			}
		}
	} else if is_loading {
		// Loading indicator is drawn separately, not here
	}
	if lines.len <= max_lines {
		return lines
	}
	return lines[lines.len - max_lines..]
}

// === Frame rendering ===

struct VisibleWindow {
	lines       []RenderLine
	indicator   string
	indent_rows int
}

fn calculate_visible_window(all_lines []RenderLine, chat_height int, scroll_offset int) VisibleWindow {
	if all_lines.len <= chat_height {
		return VisibleWindow{
			lines: all_lines
			indicator: ''
			indent_rows: 0
		}
	}

	// Clamp scroll_offset
	mut clamped := scroll_offset
	mut max_offset := all_lines.len - chat_height
	if clamped > max_offset {
		clamped = max_offset
	}
	if clamped < 0 {
		clamped = 0
	}

	// Calculate visible window
	mut start := all_lines.len - chat_height - clamped
	if start < 0 {
		start = 0
	}
	mut end := start + chat_height
	if end > all_lines.len {
		end = all_lines.len
	}

	mut indent_rows := 0
	mut indicator := ''
	if clamped > 0 {
		indicator = '↑ ${clamped} lines (scroll down to bottom)'
		indent_rows = 1
	}

	return VisibleWindow{
		lines: all_lines[start..end]
		indicator: indicator
		indent_rows: indent_rows
	}
}

pub fn on_frame(x voidptr) {
	mut app := unsafe { &App(x) }
	app.ctx.clear()
	width := app.ctx.window_width
	height := app.ctx.window_height

	// Update spinner frame
	app.spinner_frame = (app.spinner_frame + 1) % spinner_frames.len

	// Header (always visible)
	mut row := draw_header(mut app, width)

	// Calculate layout
	footer_height := 1
	input_box_height := 3

	mut bottom_area_height := input_box_height + footer_height

	if app.mode != .normal {
		// Selector mode
		mut max_vis := selector_max_visible
		if max_vis > app.selector.filtered.len {
			max_vis = app.selector.filtered.len
		}
		selector_height := 1 + 1 + max_vis + 1 + 1
		bottom_area_height = selector_height + footer_height
	} else {
		// Autocomplete + input box
		if app.ac_visible && app.ac_items.len > 0 {
			mut ac_count := app.ac_items.len
			if ac_count > 5 {
				ac_count = 5
			}
			bottom_area_height = input_box_height + footer_height + ac_count
		}
		// Loading indicator takes 1 line above input box
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
	// Build all chat lines (no limit), then apply scroll offset
	all_lines := build_chat_lines(app.messages, app.streaming_text, app.streaming_thinking, app.is_loading, app.status, chat_width, 10000)

	visible := calculate_visible_window(all_lines, chat_height, app.scroll_offset)
	mut visible_lines := visible.lines.clone()

	// Show scroll indicator if scrolled up
	if visible.indicator.len > 0 {
		apply_color(mut app.ctx, 'dim')
		app.ctx.draw_text(1, row, truncate_by_width(visible.indicator, chat_width))
		app.ctx.reset()
		row++
		// Adjust visible lines to fit
		if visible_lines.len > chat_height - 1 {
			visible_lines = visible_lines[1..].clone()
		}
	}

	for line in visible_lines {
		if row >= chat_end {
			break
		}
		apply_color(mut app.ctx, line.color)
		app.ctx.draw_text(1, row, truncate_by_width(line.text, chat_width))
		app.ctx.reset()
		row++
	}

	// Bottom area (selector or input)
	draw_bottom_area(mut app, width, chat_end)

	// Footer
	footer_y := height
	draw_footer(mut app, width, footer_y)

	// Cursor position
	position_cursor(mut app, width, chat_end)

	app.ctx.flush()
}

fn draw_footer(mut app App, width int, y int) {
	apply_color(mut app.ctx, 'dim')
	cwd := get_cwd_short()
	footer_text := 'wink v${app.version} • ${app.ag.get_model()} • ${app.ag.get_effort()} • ${cwd}'
	app.ctx.draw_text(1, y, truncate_by_width(footer_text, width))
	app.ctx.reset()
}

fn position_cursor(mut app App, width int, chat_end int) {
	app.ctx.show_cursor()
	if app.mode != .normal {
		// Cursor in selector filter input
		filter_visible := tail_by_width(app.selector.filter.string(), width - visual_width('│ > ') - visual_width('│'))
		filter_cursor_x := 1 + visual_width('│ > ') + visual_width(filter_visible)
		app.ctx.set_cursor_position(filter_cursor_x, chat_end + 1)
	} else {
		// Cursor in main input
		input_prefix := '│ > '
		content_width := width - visual_width(input_prefix) - visual_width('│')
		_, cursor_col := get_input_view(app.input, app.cursor_pos, content_width)

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
		cursor_x := 1 + visual_width(input_prefix) + cursor_col
		app.ctx.set_cursor_position(cursor_x, input_y + 1)
	}
}

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

// === Header rendering ===

fn draw_header(mut app App, width int) int {
	mut row := 1

	if app.header_mode == .full {
		// Full ASCII logo
		for logo_line in logo_lines {
			if row > 20 {
				break
			}
			apply_color(mut app.ctx, 'accent')
			app.ctx.draw_text(1, row, truncate_by_width(logo_line, width))
			app.ctx.reset()
			row++
		}
		// Version + model + cwd
		apply_color(mut app.ctx, 'dim')
		info := '  wink v${app.version} • ${app.ag.get_model()} • ${get_cwd_short()}'
		app.ctx.draw_text(1, row, truncate_by_width(info, width))
		app.ctx.reset()
		row++
		// Hints
		apply_color(mut app.ctx, 'dim')
		app.ctx.draw_text(1, row, '  esc to interrupt • ctrl+c to quit • ctrl+l to clear • /help for commands')
		app.ctx.reset()
		row++
	} else {
		// Compact header: single line
		apply_color(mut app.ctx, 'accent')
		app.ctx.draw_text(1, row, 'wink')
		app.ctx.reset()
		apply_color(mut app.ctx, 'dim')
		info := ' v${app.version} • ${app.ag.get_model()} • ${get_cwd_short()}'
		app.ctx.draw_text(1 + 4, row, truncate_by_width(info, width - 4))
		app.ctx.reset()
		row++
	}

	return row
}

// === Loading indicator rendering ===

fn draw_loading_indicator(mut app App, width int, y int) {
	spinner := spinner_frames[app.spinner_frame % spinner_frames.len]

	// Calculate elapsed time
	mut elapsed_str := ''
	if app.loading_start > 0 {
		elapsed := (time.ticks() - app.loading_start) / 1000
		if elapsed < 60 {
			elapsed_str = '${elapsed}s'
		} else {
			mut m := elapsed / 60
			s := elapsed % 60
			elapsed_str = '${m}m${s}s'
		}
	}

	// Build status line: spinner + status + (elapsed · esc to cancel)
	apply_color(mut app.ctx, 'accent')
	app.ctx.draw_text(1, y, spinner)
	app.ctx.reset()

	mut status_text := ' ' + app.status
	if elapsed_str.len > 0 {
		status_text += ' (${elapsed_str} · esc to cancel)'
	} else {
		status_text += ' (esc to cancel)'
	}
	apply_color(mut app.ctx, 'dim')
	app.ctx.draw_text(1 + visual_width(spinner), y, truncate_by_width(status_text, width - visual_width(spinner)))
	app.ctx.reset()
}

// === Input box rendering ===

fn draw_input_box(mut app App, width int, y_top int) {
	border_color := if app.is_loading { 'border_focus' } else { 'border' }

	// Top border
	apply_color(mut app.ctx, border_color)
	top_border := '┌' + '─'.repeat(width - 2) + '┐'
	app.ctx.draw_text(1, y_top, truncate_by_width(top_border, width))
	app.ctx.reset()

	// Input line
	input_y := y_top + 1
	input_prefix := '│ > '
	input_suffix := '│'
	content_width := width - visual_width(input_prefix) - visual_width(input_suffix)

	visible_text, _ := get_input_view(app.input, app.cursor_pos, content_width)

	apply_color(mut app.ctx, border_color)
	app.ctx.draw_text(1, input_y, input_prefix)
	app.ctx.reset()

	apply_color(mut app.ctx, 'green')
	app.ctx.draw_text(1 + visual_width(input_prefix), input_y, visible_text)
	app.ctx.reset()

	// Pad remaining space and right border
	pad_start := 1 + visual_width(input_prefix) + visual_width(visible_text)
	pad_width := width - visual_width(input_suffix) - visual_width(input_prefix) - visual_width(visible_text)
	if pad_width > 0 {
		app.ctx.draw_text(pad_start, input_y, ' '.repeat(pad_width))
	}
	apply_color(mut app.ctx, border_color)
	app.ctx.draw_text(width - visual_width(input_suffix) + 1, input_y, input_suffix)
	app.ctx.reset()

	// Bottom border
	bottom_y := y_top + 2
	apply_color(mut app.ctx, border_color)
	bottom_border := '└' + '─'.repeat(width - 2) + '┘'
	app.ctx.draw_text(1, bottom_y, truncate_by_width(bottom_border, width))
	app.ctx.reset()
}

// === Selector rendering ===

fn draw_selector(mut app App, width int, y_top int) int {
	title := app.selector.title

	total_items := app.selector.filtered.len
	mut max_vis := selector_max_visible
	if total_items > max_vis {
		max_vis = total_items
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
		suffix_truncated := truncate_by_width(suffix, item_content_width - visual_width(display_truncated))

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

// === Autocomplete rendering ===

fn draw_autocomplete(mut app App, width int, y_top int) {
	// Draw autocomplete items above the input box (top to bottom)
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

// === Event handling ===

fn handle_selector_event(mut app App, e &termui.Event) {
	if e.typ != .key_down {
		return
	}
	match e.code {
		.escape { app.close_selector() }
		.enter { app.selector.confirm() }
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

fn handle_normal_event(mut app App, e &termui.Event) {
	if e.typ != .key_down {
		return
	}

	// Ctrl combinations
	if e.modifiers == .ctrl {
		match e.code {
			.l {
				app.messages = []ChatMessage{}
				app.streaming_text = ''
				app.header_mode = .full
				app.ag.clear_conversation()
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
			else {}
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
				app.save_session()
				exit(0)
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
		.enter { app.submit_input() }
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
		.home { app.cursor_pos = 0 }
		.end { app.cursor_pos = app.input.len }
		.tab { app.autocomplete_accept() }
		.up {
			if app.ac_visible && app.ac_items.len > 0 {
				if app.ac_selected > 0 {
					app.ac_selected--
				} else {
					app.ac_selected = app.ac_items.len - 1
				}
			} else if app.history_index > 0 {
				app.history_index--
				app.input = app.input_history[app.history_index].runes()
				app.cursor_pos = app.input.len
			}
		}
		.down {
			if app.ac_visible && app.ac_items.len > 0 {
				if app.ac_selected < app.ac_items.len - 1 {
					app.ac_selected++
				} else {
					app.ac_selected = 0
				}
			} else if app.history_index < app.input_history.len {
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
		else {
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
}

fn on_event(e &termui.Event, x voidptr) {
	mut app := unsafe { &App(x) }

	// Windows IME fix: CJK characters produce fake key codes from term.ui.
	// Directly insert the UTF-8 characters instead of processing the key code.
	$if windows {
		if is_cjk_event(e) {
			for r in e.utf8.runes() {
				if r >= 32 {
					app.insert_rune_at_cursor(r)
				}
			}
			app.update_autocomplete()
			return
		}
	}

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

// === Public entry point ===

pub fn start(mut ag agent.Agent, version string) {
	mut app := &App{
		ag: &ag
		version: version
		// Load existing session if configured
		session_id: ag.config.current_session_id
		session_path: ag.config.current_session_path
	}

	// Load session messages if resuming
	if app.session_path.len > 0 {
		if s := session.load_session(app.session_path) {
			for msg in s.messages {
				app.messages << ChatMessage{
					role: msg.role
					text: msg.text
					time: msg.timestamp
					tool_status: msg.tool_status
				}
				// Also restore into LLM client so the model sees history
				if msg.role == 'user' || msg.role == 'assistant' {
					app.ag.client.messages << llm.Message{
						role: msg.role
						text: msg.text
						content: []llm.ContentBlock{}
					}
				}
			}
			if app.messages.len > 0 {
				app.header_mode = .compact
			}
		}
	}

	app.ctx = termui.init(
		user_data: app
		event_fn: on_event
		frame_fn: on_frame
		frame_rate: frame_rate
		hide_cursor: false
		capture_events: true
		window_title: 'Wink Code'
	)

	$if windows {
		patch_console_mode()
	}

	// Start MCP servers in background after TUI is ready
	go fn [mut app] () {
		app.ag.mcp_manager.start_eager_servers()
	}()

	app.ctx.run() or { eprintln('TUI error: ${err}') }

	// Stop MCP servers on exit
	app.ag.mcp_manager.stop_all()

	// Save session on exit
	app.save_session()
}
