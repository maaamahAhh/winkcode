module tui

import time
import compact

// submit_input handles submission of current prompt or command.
pub fn (mut app App) submit_input() {
	app.flush_session()
	if app.is_loading {
		return
	}
	prompt := app.input.string().trim_space()
	if prompt.len == 0 {
		return
	}
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
	app.status = 'Waiting for model...'
	app.is_loading = true
	app.loading_start = time.ticks()
	app.scroll_offset = 0
	go app.run_query(prompt)
}

fn (mut app App) handle_command(cmd string) {
	parts := cmd.split(' ')
	match parts[0] {
		'/model' {
			app.cmd_model(parts)
		}
		'/effort' {
			app.cmd_effort(parts)
		}
		'/clear' {
			app.cmd_clear()
		}
		'/compact' {
			app.cmd_compact(parts)
		}
		'/retry' {
			app.cmd_retry()
		}
		'/help' {
			app.cmd_help()
		}
		'/mcp' {
			app.cmd_mcp(parts)
		}
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

fn (mut app App) cmd_compact(parts []string) {
	if app.ag.client.messages.len <= 2 {
		app.push_message('system', 'Context is too small to compact.')
		return
	}
	instructions := if parts.len > 1 { parts[1..].join(' ') } else { '' }
	app.status = 'Compacting context...'
	app.is_loading = true
	go fn [mut app, instructions] () {
		summary := compact.compact(mut app.ag.client, instructions) or {
			app.mu.lock()
			app.is_loading = false
			app.status = ''
			app.mu.unlock()
			app.push_message('error', 'Compaction failed: ${err.str()}')
			return
		}
		app.mu.lock()
		app.is_loading = false
		app.status = ''
		app.session_dirty = true
		app.mu.unlock()
		app.push_message('compaction', summary)
	}()
}

fn (mut app App) cmd_retry() {
	if app.is_loading {
		app.push_message('system', 'Agent is already running. Press esc to interrupt first.')
		return
	}
	if app.ag.client.messages.len == 0 {
		app.push_message('system', 'No previous conversation to retry.')
		return
	}

	app.mu.lock()

	// 1. Find the last real user prompt in client history (excluding tool results)
	mut last_client_user_idx := -1
	for i := app.ag.client.messages.len - 1; i >= 0; i-- {
		msg := app.ag.client.messages[i]
		if msg.role == 'user' && !msg.content.any(it.typ == 'tool_result') {
			last_client_user_idx = i
			break
		}
	}
	if last_client_user_idx == -1 {
		app.mu.unlock()
		app.push_message('system', 'No user message to retry.')
		return
	}

	// 2. Roll back client history so it cleanly ends at the last user message
	app.ag.client.messages = app.ag.client.messages[..last_client_user_idx + 1].clone()

	// 3. Roll back UI messages so it cleanly ends at the last user message
	mut last_ui_user_idx := -1
	for i := app.messages.len - 1; i >= 0; i-- {
		if app.messages[i].role == 'user' {
			last_ui_user_idx = i
			break
		}
	}
	if last_ui_user_idx >= 0 {
		app.messages = app.messages[..last_ui_user_idx + 1].clone()
	}

	app.streaming_text = ''
	app.streaming_thinking = ''
	app.streaming_tool_name = ''
	app.streaming_tool_args = ''
	app.status = 'Waiting for model...'
	app.is_loading = true
	app.loading_start = time.ticks()
	app.scroll_offset = 0
	app.session_dirty = true
	app.mu.unlock()

	go app.run_query('')
}

fn (mut app App) cmd_help() {
	msg := 'Commands:\n  /model [name] - show/switch model\n  /effort [level] - show/set effort\n  /retry - retry the last prompt\n  /help - show this help\n  /clear - clear conversation\n  /compact - compact context\n  /mcp list - list MCP servers\n  /mcp toggle <name> - enable/disable MCP server\n  ctrl+l - clear conversation\n  esc - interrupt/quit'
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

