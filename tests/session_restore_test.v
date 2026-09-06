module tests

import session
import tui



fn test_reconstruct_client_messages_basic() {
	s_msgs := [
		session.SessionMessage{
			role: 'user'
			text: 'hello'
		},
		session.SessionMessage{
			role: 'assistant'
			text: 'hi there'
		},
	]

	msgs := tui.reconstruct_client_messages(s_msgs, -1)
	assert msgs.len == 2
	assert msgs[0].role == 'user'
	assert msgs[0].text == 'hello'
	assert msgs[1].role == 'assistant'
	assert msgs[1].text == 'hi there'
}

fn test_reconstruct_client_messages_with_tool_call() {
	s_msgs := [
		session.SessionMessage{
			role: 'user'
			text: 'Fetch this page'
		},
		session.SessionMessage{
			role: 'assistant'
			text: 'Sure, fetching now.'
		},
		session.SessionMessage{
			role:       'tool_call'
			text:       'web_fetch https://huggingface.co/model (2.1s)'
			tool_id:    'call_123'
			tool_name:  'web_fetch'
			tool_input: '{"url":"https://huggingface.co/model"}'
		},
		session.SessionMessage{
			role:    'tool_result'
			text:    '# Model Card Content'
			tool_id: 'call_123'
		},
		session.SessionMessage{
			role: 'assistant'
			text: 'Here is what the page says...'
		},
	]

	msgs := tui.reconstruct_client_messages(s_msgs, -1)
	assert msgs.len == 4
	// 0: user
	assert msgs[0].role == 'user'
	assert msgs[0].text == 'Fetch this page'

	// 1: assistant with tool_use
	assert msgs[1].role == 'assistant'
	assert msgs[1].text == 'Sure, fetching now.'
	assert msgs[1].content.len == 2
	assert msgs[1].content[0].typ == 'text'
	assert msgs[1].content[1].typ == 'tool_use'
	assert msgs[1].content[1].id == 'call_123'
	assert msgs[1].content[1].name == 'web_fetch'
	assert msgs[1].content[1].input == '{"url":"https://huggingface.co/model"}'

	// 2: user with tool_result
	assert msgs[2].role == 'user'
	assert msgs[2].content.len == 1
	assert msgs[2].content[0].typ == 'tool_result'
	assert msgs[2].content[0].id == 'call_123'
	assert msgs[2].content[0].content == '# Model Card Content'
	assert !msgs[2].content[0].is_error

	// 3: assistant follow-up response
	assert msgs[3].role == 'assistant'
	assert msgs[3].text == 'Here is what the page says...'
}

fn test_reconstruct_legacy_session_without_explicit_tool_fields() {
	// In older sessions, tool_name and tool_input were not saved, but text has display title
	s_msgs := [
		session.SessionMessage{
			role: 'user'
			text: 'Search for DeepSeek'
		},
		session.SessionMessage{
			role:    'tool_call'
			text:    'web_search "deepseek v4" (1.5s)'
			tool_id: 'call_old_1'
		},
		session.SessionMessage{
			role:    'tool_result'
			text:    'Found 5 results'
			tool_id: 'call_old_1'
		},
		session.SessionMessage{
			role: 'assistant'
			text: 'DeepSeek is a powerful model.'
		},
	]

	msgs := tui.reconstruct_client_messages(s_msgs, -1)
	assert msgs.len == 4
	assert msgs[0].role == 'user'

	// Assistant message created from tool_call
	assert msgs[1].role == 'assistant'
	assert msgs[1].content.len == 1
	assert msgs[1].content[0].typ == 'tool_use'
	assert msgs[1].content[0].id == 'call_old_1'
	assert msgs[1].content[0].name == 'web_search'
	assert msgs[1].content[0].input.contains('deepseek v4')

	// Tool result
	assert msgs[2].role == 'user'
	assert msgs[2].content.len == 1
	assert msgs[2].content[0].typ == 'tool_result'
	assert msgs[2].content[0].id == 'call_old_1'
	assert msgs[2].content[0].content == 'Found 5 results'

	// Assistant follow-up
	assert msgs[3].role == 'assistant'
	assert msgs[3].text == 'DeepSeek is a powerful model.'
}

fn test_scroll_clamping_at_top_and_bottom() {
	mut lines := []tui.RenderLine{}
	for i in 0 .. 50 {
		lines << tui.RenderLine{
			text: 'Line ${i}'
		}
	}
	chat_height := 10
	max_offset := lines.len - chat_height // 40

	// 1. At bottom: scroll_offset = 0
	win_bottom := tui.calculate_visible_window(lines, chat_height, 0)
	assert win_bottom.lines.len == 10
	assert win_bottom.lines[0].text == 'Line 40'
	assert win_bottom.lines[9].text == 'Line 49'
	assert win_bottom.indicator == ''

	// 2. Exactly at top: scroll_offset = max_offset (40)
	win_top := tui.calculate_visible_window(lines, chat_height, max_offset)
	assert win_top.lines.len == 10
	assert win_top.lines[0].text == 'Line 0'
	assert win_top.lines[9].text == 'Line 9'
	assert win_top.indicator.contains('40 lines')

	// 3. Trying to scroll past top: scroll_offset = 100
	// calculate_visible_window must clamp to max_offset without crashing or overshooting
	win_over := tui.calculate_visible_window(lines, chat_height, 100)
	assert win_over.lines.len == 10
	assert win_over.lines[0].text == 'Line 0'
	assert win_over.lines[9].text == 'Line 9'
	assert win_over.indicator.contains('40 lines')

	// 4. In App: simulating mouse scroll past top and immediate downward response
	mut app := tui.App{
		scroll_offset:     max_offset
		max_scroll_offset: max_offset
	}

	// Scroll up at top: must NOT exceed max_scroll_offset
	app.scroll_offset += 3
	if app.scroll_offset > app.max_scroll_offset {
		app.scroll_offset = app.max_scroll_offset
	}
	assert app.scroll_offset == max_offset

	// Now scroll down 1 notch (3 lines): must immediately become max_offset - 3
	app.scroll_offset -= 3
	if app.scroll_offset < 0 {
		app.scroll_offset = 0
	}
	assert app.scroll_offset == max_offset - 3

	// Next frame calculate_visible_window immediately shifts by 3 lines
	win_shift := tui.calculate_visible_window(lines, chat_height, app.scroll_offset)
	assert win_shift.lines[0].text == 'Line 3'
}
