module tui

import term.ui as termui
import time
import os
import json2
import agent
import llm
import session
import sync
import tools

$if windows {
	fn C.SetConsoleOutputCP(w_code_page_id u32) bool
}

const max_messages = 200
const frame_rate = 24

// === Types ===

pub struct ChatMessage {
pub:
	role        string
	text        string
	thinking    string
	time        string
	tool_status string // '', 'pending', 'success', 'error'
	tool_id     string
	parent_id   string
	tool_name   string
	tool_input  string
}

pub struct RenderLine {
pub mut:
	text  string
	color string
	segs  []RenderLine // inline styled segments; rendered by segment when non-empty
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
	mu                  &sync.Mutex     = sync.new_mutex()
	ctx                 &termui.Context = unsafe { nil }
	ag                  &agent.Agent    = unsafe { nil }
	messages            []ChatMessage
	input               []rune
	cursor_pos          int
	streaming_text      string
	streaming_thinking  string
	streaming_tool_name string // tool currently being streamed by the model
	streaming_tool_args string // its streaming arguments
	expand_tool_results bool   // ctrl+o toggles full tool result display
	status              string
	is_loading          bool
	loading_start       i64
	version             string
	header_mode         HeaderMode = .full
	mode                AppMode    = .normal
	spinner_frame       int
	// Selector state
	selector SelectorState
	// Autocomplete state
	ac_items    []AutocompleteItem
	ac_selected int
	ac_visible  bool
	// Scroll state
	scroll_offset     int // 0 = bottom (latest), >0 = scrolled up N lines
	max_scroll_offset int // maximum valid scroll offset based on content height
	// Input history
	input_history []string
	history_index int
	// Tool timing state
	tool_start_times map[string]i64
	// Session state
	session_id   string
	session_path string
	// Debounce session saves
	session_dirty  bool
	last_save_time i64
	// Key event timing for paste detection
	last_key_time i64
	burst_count   int
	// Git branch cache
	cached_git_branch string
	last_git_check    i64
}

// === Message management ===

pub fn (mut app App) push_message(role string, text string) {
	app.mu.lock()
	app.messages << ChatMessage{
		role: role
		text: text
		time: now_formatted()
	}
	if app.messages.len > max_messages {
		app.messages = app.messages[app.messages.len - max_messages..]
	}
	if app.header_mode == .full {
		app.header_mode = .compact
	}
	app.mu.unlock()
	app.save_session()
}

pub fn (mut app App) push_assistant_message(text string, thinking string) {
	app.mu.lock()
	app.messages << ChatMessage{
		role:     'assistant'
		text:     text
		thinking: thinking
		time:     now_formatted()
	}
	if app.messages.len > max_messages {
		app.messages = app.messages[app.messages.len - max_messages..]
	}
	if app.header_mode == .full {
		app.header_mode = .compact
	}
	app.mu.unlock()
	app.save_session()
}

pub fn (mut app App) push_tool_message(name string, status string, result_preview string, is_error bool) {
	app.mu.lock()
	tool_status := if is_error {
		'error'
	} else if status == 'done' {
		'success'
	} else {
		'pending'
	}
	app.messages << ChatMessage{
		role:        'tool_call'
		text:        name
		time:        now_formatted()
		tool_status: tool_status
	}
	if result_preview.len > 0 {
		result_role := if is_error { 'tool_error' } else { 'tool_result' }
		app.messages << ChatMessage{
			role: result_role
			text: result_preview
			time: now_formatted()
		}
	}
	if app.messages.len > max_messages {
		app.messages = app.messages[app.messages.len - max_messages..]
	}
	if app.header_mode == .full {
		app.header_mode = .compact
	}
	app.mu.unlock()
	app.save_session()
}

fn now_formatted() string {
	return time.now().custom_format('HH:mm:ss')
}

// === Session management ===

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
		model := app.ag.get_model()
		provider := app.ag.config.get_model_provider(model)
		mut s := session.new_session(model, provider)
		s.session_path = session.session_file_path(s.header)
		app.session_id = s.header.id
		app.session_path = s.session_path
		app.session_append_all(mut s)
	} else {
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
	app.mu.lock()
	msgs_snapshot := app.messages.clone()
	app.mu.unlock()

	s.messages = []session.SessionMessage{}
	for msg in msgs_snapshot {
		s.messages << session.SessionMessage{
			role:        msg.role
			text:        msg.text
			thinking:    msg.thinking
			timestamp:   msg.time
			tool_status: msg.tool_status
			tool_id:     msg.tool_id
			parent_id:   msg.parent_id
			tool_name:   msg.tool_name
			tool_input:  msg.tool_input
		}
	}
	s.save() or {}
	app.session_id = s.header.id
	app.session_path = s.session_path
}

fn (mut app App) session_append_all(mut s session.Session) {
	s.save() or {}
	app.session_id = s.header.id
	app.session_path = s.session_path
}

fn parse_tool_call_from_message(msg session.SessionMessage) (string, string) {
	if msg.tool_name.len > 0 {
		return msg.tool_name, msg.tool_input
	}
	mut raw := msg.text.trim_space()
	if raw.ends_with('s)') {
		if paren_idx := raw.last_index('(') {
			raw = raw[..paren_idx].trim_space()
		}
	}
	if raw.starts_with('subagent: ') {
		prompt := raw['subagent: '.len..].trim_space()
		return 'subagent', json2.encode({'prompt': prompt})
	}
	parts := raw.split(' ')
	if parts.len == 0 {
		return 'unknown', '{}'
	}
	name := parts[0]
	rest := if parts.len > 1 { raw[name.len..].trim_space() } else { '' }
	mut input_map := map[string]string{}
	match name {
		'web_fetch' {
			input_map['url'] = rest
		}
		'web_search' {
			mut q := rest
			if q.starts_with('"') && q.ends_with('"') && q.len >= 2 {
				q = q[1..q.len - 1]
			}
			input_map['query'] = q
		}
		'read', 'write', 'edit' {
			input_map['path'] = rest
		}
		'bash', 'pwsh', 'cmd' {
			input_map['command'] = rest
		}
		'list_dir' {
			input_map['path'] = if rest.len > 0 { rest } else { '.' }
		}
		'glob', 'grep' {
			input_map['pattern'] = rest
		}
		else {
			if rest.len > 0 {
				input_map['input'] = rest
			}
		}
	}
	return name, json2.encode(input_map)
}

pub fn reconstruct_client_messages(s_messages []session.SessionMessage, compact_idx int) []llm.Message {
	mut result := []llm.Message{}

	if compact_idx >= 0 && compact_idx < s_messages.len {
		result << llm.Message{
			role:    'user'
			text:    '[Context was compacted. Prior conversation summarized below.]\n\n' + s_messages[compact_idx].text
			content: []llm.ContentBlock{}
		}
	}

	mut i := if compact_idx >= 0 { compact_idx + 1 } else { 0 }
	for i < s_messages.len {
		msg := s_messages[i]

		match msg.role {
			'user' {
				result << llm.Message{
					role:    'user'
					text:    msg.text
					content: []llm.ContentBlock{}
				}
				i++
			}
			'assistant' {
				mut j := i + 1
				mut tool_calls := []session.SessionMessage{}
				for j < s_messages.len && s_messages[j].role == 'tool_call' {
					tool_calls << s_messages[j]
					j++
				}

				if tool_calls.len > 0 {
					mut blocks := []llm.ContentBlock{}
					if msg.text.len > 0 {
						blocks << llm.ContentBlock{
							typ:  'text'
							text: msg.text
						}
					}
					for tc_msg in tool_calls {
						t_name, t_input := parse_tool_call_from_message(tc_msg)
						call_id := if tc_msg.tool_id.len > 0 { tc_msg.tool_id } else { 'call_${tc_msg.timestamp}' }
						blocks << llm.ContentBlock{
							typ:   'tool_use'
							id:    call_id
							name:  t_name
							input: t_input
						}
					}
					result << llm.Message{
						role:           'assistant'
						text:           msg.text
						thinking:       msg.thinking
						thinking_field: if msg.thinking.len > 0 { 'reasoning_content' } else { '' }
						content:        blocks
					}
					i = j
				} else {
					if result.len > 0 && result.last().role == 'assistant' {
						last_idx := result.len - 1
						if msg.text.len > 0 {
							if result[last_idx].text.len > 0 {
								result[last_idx].text += '\n\n' + msg.text
							} else {
								result[last_idx].text = msg.text
							}
							result[last_idx].content << llm.ContentBlock{
								typ:  'text'
								text: msg.text
							}
						}
						if msg.thinking.len > 0 {
							result[last_idx].thinking = msg.thinking
							result[last_idx].thinking_field = 'reasoning_content'
						}
					} else {
						mut blocks := []llm.ContentBlock{}
						if msg.text.len > 0 {
							blocks << llm.ContentBlock{
								typ:  'text'
								text: msg.text
							}
						}
						result << llm.Message{
							role:           'assistant'
							text:           msg.text
							thinking:       msg.thinking
							thinking_field: if msg.thinking.len > 0 { 'reasoning_content' } else { '' }
							content:        blocks
						}
					}
					i++
				}
			}
			'tool_call' {
				mut j := i
				mut blocks := []llm.ContentBlock{}
				for j < s_messages.len && s_messages[j].role == 'tool_call' {
					tc_msg := s_messages[j]
					t_name, t_input := parse_tool_call_from_message(tc_msg)
					call_id := if tc_msg.tool_id.len > 0 { tc_msg.tool_id } else { 'call_${tc_msg.timestamp}' }
					blocks << llm.ContentBlock{
						typ:   'tool_use'
						id:    call_id
						name:  t_name
						input: t_input
					}
					j++
				}
				result << llm.Message{
					role:    'assistant'
					content: blocks
				}
				i = j
			}
			'tool_result', 'tool_error' {
				mut j := i
				mut blocks := []llm.ContentBlock{}
				for j < s_messages.len && (s_messages[j].role == 'tool_result' || s_messages[j].role == 'tool_error') {
					tr_msg := s_messages[j]
					call_id := if tr_msg.tool_id.len > 0 { tr_msg.tool_id } else { 'call_${tr_msg.timestamp}' }
					is_err := tr_msg.role == 'tool_error'
					blocks << llm.ContentBlock{
						typ:      'tool_result'
						id:       call_id
						content:  tr_msg.text
						is_error: is_err
					}
					j++
				}
				result << llm.Message{
					role:    'user'
					content: blocks
				}
				i = j
			}
			else {
				i++
			}
		}
	}

	return result
}

fn get_cwd_short() string {
	cwd := os.getwd()
	home := os.home_dir()
	if home.len > 0 && cwd.starts_with(home) {
		return '~' + cwd[home.len..]
	}
	return cwd
}

// === Public entry point ===

pub fn start(mut ag agent.Agent, version string) {
	mut app := &App{
		ag:           &ag
		version:      version
		session_id:   ag.config.current_session_id
		session_path: ag.config.current_session_path
	}

	if app.session_path.len > 0 {
		if s := session.load_session(app.session_path) {
			mut compact_idx := -1
			for idx, msg in s.messages {
				if msg.role == 'compaction' {
					compact_idx = idx
				}
			}
			for msg in s.messages {
				app.messages << ChatMessage{
					role:        msg.role
					text:        msg.text
					thinking:    msg.thinking
					time:        msg.timestamp
					tool_status: msg.tool_status
					tool_id:     msg.tool_id
					parent_id:   msg.parent_id
					tool_name:   msg.tool_name
					tool_input:  msg.tool_input
				}
			}
			app.ag.client.messages = reconstruct_client_messages(s.messages, compact_idx)
			if app.messages.len > 0 {
				app.header_mode = .compact
			}
		}
	}

	$if windows {
		// Workaround for upstream term.ui: https://github.com/vlang/v/pull/28072
		// Ensure non-ASCII/UTF-8 characters render properly on Windows console
		C.SetConsoleOutputCP(65001)
	}

	app.ctx = termui.init(
		user_data:      app
		event_fn:       on_event
		frame_fn:       on_frame
		frame_rate:     frame_rate
		hide_cursor:    false
		capture_events: true
		mouse_enabled:  true
		window_title:   'Wink Code'
	)

	// Start MCP servers in background after TUI is ready
	go fn [mut app] () {
		app.ag.mcp_manager.start_eager_servers()
	}()

	app.ctx.run() or { eprintln('TUI error: ${err}') }

	// Stop MCP servers on exit
	app.ag.mcp_manager.stop_all()

	// Terminate any running background tasks
	tools.cleanup_tasks()

	// Save session on exit
	app.save_session()
}
