module llm

import json2

struct OpenAIChunk {
	choices []OpenAIChoice
}

struct OpenAIChoice {
	delta         OpenAIChoiceDelta
	finish_reason string @[json: 'finish_reason']
}

struct OpenAIChoiceDelta {
	content           string
	reasoning_content string @[json: 'reasoning_content']
	reasoning         string
	tool_calls        []OpenAIToolCall
}

struct OpenAIToolCall {
	index    int
	id       string
	typ      string @[json: 'type']
	function OpenAIToolCallFunction
}

struct OpenAIToolCallFunction {
	name      string
	arguments string
}

fn handle_openai_delta(mut state StreamState, json_str string, on_text OnStreamText, _on_tool_call OnToolCall, on_thinking OnStreamText, on_tool_stream OnToolStream) {
	chunk := json2.decode[OpenAIChunk](json_str) or { return }
	if chunk.choices.len == 0 {
		return
	}
	delta := chunk.choices[0].delta

	mut reasoning_field := ''
	mut thinking := delta.reasoning_content
	if thinking.len > 0 {
		reasoning_field = 'reasoning_content'
	} else if delta.reasoning.len > 0 {
		thinking = delta.reasoning
		reasoning_field = 'reasoning'
	}
	if reasoning_field.len > 0 {
		if state.reasoning_field.len == 0 {
			state.reasoning_field = reasoning_field
		}
		state.thinking += thinking
		if on_thinking != unsafe { nil } {
			on_thinking(thinking)
		}
	}

	if delta.content.len > 0 {
		state.full_text += delta.content
		if on_text != unsafe { nil } {
			on_text(delta.content)
		}
	}

	for tc in delta.tool_calls {
		idx := tc.index
		for state.pending_tools.len <= idx {
			state.pending_tools << PendingToolCall{}
		}
		if tc.id.len > 0 {
			state.pending_tools[idx].id = tc.id
		}
		if tc.function.name.len > 0 {
			state.pending_tools[idx].name += tc.function.name
		}
		if tc.function.arguments.len > 0 {
			state.pending_tools[idx].arguments += tc.function.arguments
		}
		if on_tool_stream != unsafe { nil } {
			on_tool_stream(state.pending_tools[idx].name, state.pending_tools[idx].arguments)
		}
	}
}

fn finalize_openai_tool_calls(mut state StreamState, on_tool_call OnToolCall) {
	for pt in state.pending_tools {
		if pt.name.len == 0 {
			continue
		}
		mut call_id := pt.id
		if call_id.len == 0 {
			state.tool_call_seq++
			call_id = 'call_${state.tool_call_seq}'
		}
		mut input_json := pt.arguments.trim_space()
		if input_json.len == 0 {
			input_json = '{}'
		}
		tc := ToolCall{
			id:    call_id
			name:  pt.name
			input: input_json
		}
		state.tool_calls << tc
		if on_tool_call != unsafe { nil } {
			on_tool_call(tc)
		}
	}
	state.pending_tools = []PendingToolCall{}
}

fn process_openai_line(mut state StreamState, line string, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText, on_tool_stream OnToolStream) {
	if line.len == 0 {
		return
	}
	if !line.starts_with('data:') {
		return
	}
	json_str := line[5..].trim_space()
	if json_str == '[DONE]' {
		state.openai_done = true
		return
	}
	handle_openai_delta(mut state, json_str, on_text, on_tool_call, on_thinking, on_tool_stream)
}

fn (c &Client) build_request_body_openai() string {
	mut fields := []string{}
	fields << '"model":${json2.encode(c.model)}'
	fields << '"max_tokens":${c.max_tokens}'

	if c.reasoning && c.effort.len > 0 {
		effort_val := if c.effort == 'max' { 'high' } else { c.effort }
		fields << '"reasoning_effort":${json2.encode(effort_val)}'
	}

	fields << '"messages":${build_openai_messages_json(c.messages, c.system_prompt,
		c.messages.any(it.thinking_field.len > 0))}'
	fields << '"tools":${c.tool_schemas}'
	fields << '"stream":true'
	return '{${fields.join(',')}}'
}

fn build_openai_messages_json(messages []Message, system_prompt string, reasoning_mode bool) string {
	mut parts := []string{}
	parts << '{"role":"system","content":${json2.encode(system_prompt)}}'
	mut pending_tool_ids := []string{}

	for msg in messages {
		if msg.role == 'user' && msg.content.len > 0 {
			tool_result_msgs := build_openai_tool_result_messages(msg)
			for tool_msg in tool_result_msgs {
				parts << tool_msg
			}
			for block in msg.content {
				if block.typ == 'tool_result' {
					pending_tool_ids = pending_tool_ids.filter(it != block.id)
				}
			}
			continue
		}

		if pending_tool_ids.len > 0 {
			for tid in pending_tool_ids {
				parts << '{"role":"tool","tool_call_id":${json2.encode(tid)},"content":"[Operation interrupted by user]"}'
			}
			pending_tool_ids = []string{}
		}

		if msg.role == 'assistant' && msg.content.len > 0 {
			for block in msg.content {
				if block.typ == 'tool_use' && block.id.len > 0 {
					pending_tool_ids << block.id
				}
			}
		}

		parts << build_openai_message_json(msg, reasoning_mode)
	}

	if pending_tool_ids.len > 0 {
		for tid in pending_tool_ids {
			parts << '{"role":"tool","tool_call_id":${json2.encode(tid)},"content":"[Operation interrupted by user]"}'
		}
	}

	return '[${parts.join(',')}]'
}

fn build_openai_message_json(msg Message, reasoning_mode bool) string {
	if msg.content.len == 0 && msg.text.len > 0 {
		return '{"role":${json2.encode(msg.role)},"content":${json2.encode(msg.text)}}'
	} else if msg.role == 'assistant' && msg.content.len > 0 {
		mut text_content := ''
		mut tool_calls_json := []string{}
		for block in msg.content {
			match block.typ {
				'text' {
					text_content = block.text
				}
				'tool_use' {
					clean_input := sanitize_tool_input_json(block.input)
					tool_calls_json << '{"id":${json2.encode(block.id)},"type":"function","function":{"name":${json2.encode(block.name)},"arguments":${json2.encode(clean_input)}}}'
				}
				else {}
			}
		}
		mut msg_parts := []string{}
		msg_parts << '"role":${json2.encode('assistant')}'
		if text_content.len > 0 {
			msg_parts << '"content":${json2.encode(text_content)}'
		} else {
			msg_parts << '"content":null'
		}
		if msg.thinking_field.len > 0 || reasoning_mode {
			field := if msg.thinking_field.len > 0 {
				msg.thinking_field
			} else {
				'reasoning_content'
			}
			msg_parts << '"${field}":${json2.encode(msg.thinking)}'
		}
		if tool_calls_json.len > 0 {
			msg_parts << '"tool_calls":[${tool_calls_json.join(',')}]'
		}
		return '{${msg_parts.join(',')}}'
	} else {
		return '{"role":${json2.encode(msg.role)},"content":""}'
	}
}

fn build_openai_tool_result_messages(msg Message) []string {
	mut result := []string{}
	for block in msg.content {
		if block.typ != 'tool_result' {
			continue
		}
		if img := block.image_data {
			data_url := 'data:${img.mime_type};base64,${img.data}'
			result << '{"role":"tool","tool_call_id":${json2.encode(block.id)},"content":[{"type":"text","text":${json2.encode(block.content)}},{"type":"image_url","image_url":{"url":${json2.encode(data_url)}}}]}'
		} else {
			result << '{"role":"tool","tool_call_id":${json2.encode(block.id)},"content":${json2.encode(block.content)}}'
		}
	}
	return result
}
