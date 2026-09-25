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

// abort_query safely cancels the running model/tool query, finalizes pending tool calls,
// and resets streaming states.
pub fn (mut app App) abort_query() {
	app.ag.client.aborted = true
	app.is_loading = false
	app.status = ''
	app.streaming_tool_name = ''
	app.streaming_tool_args = ''
	app.commit_streaming_assistant_message()

	// Finalize any pending tool call messages so spinners stop immediately
	for i in 0 .. app.messages.len {
		if app.messages[i].role == 'tool_call' && app.messages[i].tool_status == 'pending' {
			msg := app.messages[i]
			call_id := msg.tool_id
			duration_str := app.take_tool_duration(call_id)
			dur_suffix := if duration_str.len > 0 { duration_str } else { ' (interrupted)' }
			app.messages[i] = ChatMessage{
				role:        msg.role
				text:        msg.text + dur_suffix
				time:        msg.time
				tool_status: 'error'
				tool_id:     msg.tool_id
				parent_id:   msg.parent_id
				tool_name:   msg.tool_name
				tool_input:  msg.tool_input
			}
		}
	}
	app.tool_start_times.clear()
	app.session_dirty = true
}

fn (mut app App) update_stream_speed(now i64) {
	if app.first_token_time == 0 {
		app.first_token_time = now
		return
	}
	elapsed_s := f32(now - app.first_token_time) / 1000.0
	if elapsed_s > 0.2 {
		total_chars := app.streaming_thinking.len + app.streaming_text.len + app.streaming_tool_args.len
		toks := total_chars / 4
		app.last_tok_per_sec = f32(toks) / elapsed_s
	}
}

fn app_cb_thinking(user_data voidptr, text string) {
	mut app := unsafe { &App(user_data) }
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	if app.ag.client.aborted {
		return
	}
	app.status = 'Thinking...'
	app.streaming_thinking += text
	app.update_stream_speed(time.ticks())
}

fn app_cb_text(user_data voidptr, text string) {
	mut app := unsafe { &App(user_data) }
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	if app.ag.client.aborted {
		return
	}
	app.status = 'Generating...'
	app.streaming_text += text
	app.update_stream_speed(time.ticks())
}

fn app_cb_tool_stream(user_data voidptr, name string, args string) {
	mut app := unsafe { &App(user_data) }
	app.mu.lock()
	defer {
		app.mu.unlock()
	}
	if app.ag.client.aborted {
		return
	}
	app.streaming_tool_name = name
	app.streaming_tool_args = args
	app.update_stream_speed(time.ticks())
}

fn app_cb_tool_call(user_data voidptr, call_id string, name string, input string, display string, parent_id string) {
	mut app := unsafe { &App(user_data) }
	app.mu.lock()
	app.streaming_tool_name = ''
	app.streaming_tool_args = ''
	now := time.ticks()
	if app.first_token_time > 0 {
		elapsed_s := f32(now - app.first_token_time) / 1000.0
		if elapsed_s > 0.1 {
			total_chars := app.streaming_thinking.len + app.streaming_text.len + input.len
			toks := total_chars / 4
			app.last_tok_per_sec = f32(toks) / elapsed_s
			app.last_duration_s = elapsed_s
		}
	}
	app.commit_streaming_assistant_message()
	app.first_token_time = 0
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

fn app_cb_tool_result(user_data voidptr, call_id string, _name string, preview string, is_error bool, parent_id string) {
	mut app := unsafe { &App(user_data) }
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

fn app_cb_retry(user_data voidptr, attempt int, max_attempts int, delay_s int, _err_msg string) {
	mut app := unsafe { &App(user_data) }
	app.mu.lock()
	app.status = 'API error. Retrying (${attempt}/${max_attempts}) in ${delay_s}s...'
	app.mu.unlock()
}

fn app_cb_complete(user_data voidptr) {
	mut app := unsafe { &App(user_data) }
	app.mu.lock()
	now := time.ticks()
	if app.first_token_time > 0 {
		elapsed_s := f32(now - app.first_token_time) / 1000.0
		if elapsed_s > 0.1 {
			total_chars := app.streaming_thinking.len + app.streaming_text.len + app.streaming_tool_args.len
			toks := total_chars / 4
			app.last_tok_per_sec = f32(toks) / elapsed_s
			app.last_duration_s = elapsed_s
		}
	}
	app.commit_streaming_assistant_message()
	app.first_token_time = 0
	app.status = ''
	app.is_loading = false
	app.session_dirty = true
	app.mu.unlock()
	app.flush_session()
}

fn app_cb_error(user_data voidptr, msg string) {
	mut app := unsafe { &App(user_data) }
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

pub fn (mut app App) run_query(prompt string) {
	app.mu.lock()
	app.first_token_time = 0
	app.last_tok_per_sec = 0.0
	app.last_duration_s = 0.0
	app.mu.unlock()

	cb := agent.AgentCallbacks{
		user_data:      voidptr(app)
		on_thinking:    app_cb_thinking
		on_text:        app_cb_text
		on_tool_stream: app_cb_tool_stream
		on_tool_call:   app_cb_tool_call
		on_tool_result: app_cb_tool_result
		on_retry:       app_cb_retry
		on_complete:    app_cb_complete
		on_error:       app_cb_error
	}
	app.ag.run(prompt, cb)
}
