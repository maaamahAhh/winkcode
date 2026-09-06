module tui

import time
import agent

fn (mut app App) commit_streaming_assistant_message() {
	text := app.streaming_text
	thinking := app.streaming_thinking
	app.streaming_text = ''
	app.streaming_thinking = ''
	if text.len > 0 || thinking.len > 0 {
		app.messages << ChatMessage{
			role:     'assistant'
			text:     text
			thinking: thinking
			time:     now_formatted()
		}
	}
}

fn (mut app App) take_tool_duration(call_id string) string {
	if call_id !in app.tool_start_times {
		return ''
	}
	start_ns := app.tool_start_times[call_id]
	elapsed_ns := time.now().unix_nano() - start_ns
	elapsed_ms := elapsed_ns / 1_000_000
	app.tool_start_times.delete(call_id)
	if elapsed_ms < 1000 {
		return ' (${elapsed_ms}ms)'
	}
	return ' (${f32(elapsed_ms) / 1000.0:.1f}s)'
}

fn (mut app App) update_tool_call_status(call_id string, duration_str string, status string) {
	if app.messages.len == 0 {
		return
	}
	for i := app.messages.len - 1; i >= 0; i-- {
		last := app.messages[i]
		if last.role == 'tool_call' && last.tool_status == 'pending' && last.tool_id == call_id {
			app.messages[i] = ChatMessage{
				role:        last.role
				text:        last.text + duration_str
				time:        last.time
				tool_status: status
				tool_id:     last.tool_id
				parent_id:   last.parent_id
				tool_name:   last.tool_name
				tool_input:  last.tool_input
			}
			return
		}
	}
	// Fallback if matching by tool_id didn't find pending call
	for i := app.messages.len - 1; i >= 0; i-- {
		last := app.messages[i]
		if last.role == 'tool_call' && last.tool_status == 'pending' {
			app.messages[i] = ChatMessage{
				role:        last.role
				text:        last.text + duration_str
				time:        last.time
				tool_status: status
				tool_id:     last.tool_id
				parent_id:   last.parent_id
				tool_name:   last.tool_name
				tool_input:  last.tool_input
			}
			return
		}
	}
}

pub fn (mut app App) run_query(prompt string) {
	cb := agent.AgentCallbacks{
		on_thinking:    fn [mut app] (text string) {
			if !app.ag.client.aborted {
				app.mu.lock()
				app.status = 'Thinking...'
				app.streaming_thinking += text
				app.mu.unlock()
			}
		}
		on_text:        fn [mut app] (text string) {
			if !app.ag.client.aborted {
				app.mu.lock()
				app.streaming_text += text
				app.mu.unlock()
			}
		}
		on_tool_stream: fn [mut app] (name string, args string) {
			app.mu.lock()
			app.streaming_tool_name = name
			app.streaming_tool_args = args
			app.mu.unlock()
		}
		on_tool_call:   fn [mut app] (call_id string, name string, input string, display string, parent_id string) {
			app.mu.lock()
			app.streaming_tool_name = ''
			app.streaming_tool_args = ''
			app.commit_streaming_assistant_message()
			app.tool_start_times[call_id] = time.now().unix_nano()

			title := if display.len > 0 { display } else { name }

			app.messages << ChatMessage{
				role:        'tool_call'
				text:        title
				time:        now_formatted()
				tool_status: 'pending'
				tool_id:     call_id
				parent_id:   parent_id
				tool_name:   name
				tool_input:  input
			}
			if app.header_mode == .full {
				app.header_mode = .compact
			}
			if app.tool_start_times.len > 1 {
				app.status = 'running tools (${app.tool_start_times.len} active)...'
			} else {
				app.status = 'running ${title}...'
			}
			app.mu.unlock()
		}
		on_tool_result: fn [mut app] (call_id string, name string, preview string, is_error bool, parent_id string) {
			app.mu.lock()
			status := if is_error { 'error' } else { 'success' }
			duration_str := app.take_tool_duration(call_id)
			app.update_tool_call_status(call_id, duration_str, status)

			if preview.len > 0 {
				result_role := if is_error { 'tool_error' } else { 'tool_result' }
				app.messages << ChatMessage{
					role:      result_role
					text:      preview
					time:      now_formatted()
					tool_id:   call_id
					parent_id: parent_id
				}
			}
			if app.tool_start_times.len > 0 {
				app.status = 'running tools (${app.tool_start_times.len} active)...'
			} else {
				app.status = 'Waiting for model...'
			}
			app.session_dirty = true
			app.mu.unlock()
		}
		on_retry:       fn [mut app] (attempt int, max_attempts int, delay_s int, _err_msg string) {
			app.mu.lock()
			app.status = 'API error. Retrying (${attempt}/${max_attempts}) in ${delay_s}s...'
			app.mu.unlock()
		}
		on_complete:    fn [mut app] () {
			app.mu.lock()
			app.commit_streaming_assistant_message()
			app.status = ''
			app.is_loading = false
			app.session_dirty = true
			app.mu.unlock()
			app.flush_session()
		}
		on_error:       fn [mut app] (msg string) {
			app.mu.lock()
			app.commit_streaming_assistant_message()
			app.messages << ChatMessage{
				role: 'error'
				text: msg
				time: now_formatted()
			}
			app.status = ''
			app.is_loading = false
			app.session_dirty = true
			app.mu.unlock()
			app.flush_session()
		}
	}
	app.ag.run(prompt, cb)
}
