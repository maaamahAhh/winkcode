module llm

import json2

struct AnthropicEvent {
	typ           string                 @[json: 'type']
	content_block ?AnthropicContentBlock @[json: 'content_block']
	delta         ?AnthropicEventDelta
}

struct AnthropicContentBlock {
	typ  string @[json: 'type']
	id   string
	name string
}

struct AnthropicEventDelta {
	typ          string @[json: 'type']
	partial_json string @[json: 'partial_json']
	thinking     string
	text         string
}

fn handle_block_start(mut state StreamState, json_str string, on_tool_stream OnToolStream) {
	event := json2.decode[AnthropicEvent](json_str) or { return }
	cb := event.content_block or {
		state.current_block_type = 'text'
		return
	}

	match cb.typ {
		'tool_use' {
			state.current_block_type = 'tool_use'
			state.pending_tool_id = cb.id
			state.pending_tool_name = cb.name
			state.pending_tool_input = ''
			if on_tool_stream != unsafe { nil } {
				on_tool_stream(state.pending_tool_name, state.pending_tool_input)
			}
		}
		'thinking' {
			state.current_block_type = 'thinking'
		}
		else {
			state.current_block_type = 'text'
		}
	}
}

fn handle_block_delta(mut state StreamState, json_str string, on_text OnStreamText, on_thinking OnStreamText, on_tool_stream OnToolStream) {
	event := json2.decode[AnthropicEvent](json_str) or { return }
	d := event.delta or { return }
	delta_type := if d.typ.len > 0 { d.typ } else { state.current_block_type }

	match delta_type {
		'input_json_delta', 'tool_use' {
			if d.partial_json.len > 0 {
				state.pending_tool_input += d.partial_json
				if on_tool_stream != unsafe { nil } {
					on_tool_stream(state.pending_tool_name, state.pending_tool_input)
				}
			}
		}
		'thinking_delta', 'thinking' {
			if d.thinking.len > 0 {
				state.thinking += d.thinking
				if on_thinking != unsafe { nil } {
					on_thinking(d.thinking)
				}
			}
		}
		'text_delta', 'text' {
			if d.text.len > 0 {
				state.full_text += d.text
				if on_text != unsafe { nil } {
					on_text(d.text)
				}
			}
		}
		else {
			if d.text.len > 0 {
				state.full_text += d.text
				if on_text != unsafe { nil } {
					on_text(d.text)
				}
			}
		}
	}
}

fn handle_block_stop(mut state StreamState, on_tool_call OnToolCall) {
	if state.current_block_type == 'tool_use' && state.pending_tool_id.len > 0 {
		tc := ToolCall{
			id:    state.pending_tool_id
			name:  state.pending_tool_name
			input: state.pending_tool_input
		}
		state.tool_calls << tc
		if on_tool_call != unsafe { nil } {
			on_tool_call(tc)
		}
		state.pending_tool_id = ''
		state.pending_tool_name = ''
		state.pending_tool_input = ''
	}
	state.current_block_type = ''
}

fn process_anthropic_line(mut state StreamState, line string, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText, on_tool_stream OnToolStream) {
	if line.starts_with('event:') {
		state.current_event = line[6..].trim_space()
		return
	}
	if !line.starts_with('data:') {
		return
	}
	json_str := line[5..].trim_space()
	if json_str == '[DONE]' {
		return
	}
	mut event_type := state.current_event
	state.current_event = ''

	if event_type == '' {
		if event := json2.decode[AnthropicEvent](json_str) {
			event_type = event.typ
		}
	}

	match event_type {
		'content_block_start' {
			handle_block_start(mut state, json_str, on_tool_stream)
		}
		'content_block_delta' {
			handle_block_delta(mut state, json_str, on_text, on_thinking, on_tool_stream)
		}
		'content_block_stop' {
			handle_block_stop(mut state, on_tool_call)
		}
		else {}
	}
}

fn (c &Client) build_request_body_anthropic() string {
	mut max_tokens := c.max_tokens
	mut thinking_json := ''
	if c.reasoning {
		effort := if c.effort.len > 0 { c.effort } else { 'medium' }
		budget := effort_to_budget(effort, c.max_tokens)
		if budget >= max_tokens {
			max_tokens = budget + 4096
		}
		thinking_json = '{"type":"enabled","budget_tokens":${budget}}'
	}

	mut fields := []string{}
	fields << '"model":${json2.encode(c.model)}'
	fields << '"max_tokens":${max_tokens}'
	if thinking_json.len > 0 {
		fields << '"thinking":${thinking_json}'
	}
	fields << '"system":${json2.encode(c.system_prompt)}'
	fields << '"messages":${build_anthropic_messages_json(c.messages)}'
	fields << '"tools":${c.tool_schemas}'
	fields << '"stream":true'
	return '{${fields.join(',')}}'
}

struct NormalizedMessage {
mut:
	role   string
	blocks []ContentBlock
}

fn build_anthropic_messages_json(messages []Message) string {
	mut normalized := []NormalizedMessage{}
	for msg in messages {
		mut blocks := []ContentBlock{}
		if msg.content.len > 0 {
			for b in msg.content {
				blocks << b
			}
		} else if msg.text.len > 0 {
			blocks << ContentBlock{
				typ:  'text'
				text: msg.text
			}
		}
		if blocks.len == 0 {
			continue
		}
		role := if msg.role == 'assistant' { 'assistant' } else { 'user' }
		normalized << NormalizedMessage{
			role:   role
			blocks: blocks
		}
	}

	mut merged := []NormalizedMessage{}
	for msg in normalized {
		if merged.len > 0 && merged.last().role == msg.role {
			last_idx := merged.len - 1
			for b in msg.blocks {
				merged[last_idx].blocks << b
			}
		} else {
			merged << NormalizedMessage{
				role:   msg.role
				blocks: msg.blocks.clone()
			}
		}
	}

	mut final_messages := []NormalizedMessage{}
	for i in 0 .. merged.len {
		msg := merged[i]
		if msg.role == 'assistant' {
			final_messages << msg
			mut tool_use_ids := []string{}
			for b in msg.blocks {
				if b.typ == 'tool_use' && b.id.len > 0 {
					tool_use_ids << b.id
				}
			}

			if tool_use_ids.len > 0 {
				mut tool_result_map := map[string]ContentBlock{}
				for j in (i + 1) .. merged.len {
					next_msg := merged[j]
					for b in next_msg.blocks {
						if b.typ == 'tool_result' && b.id in tool_use_ids {
							tool_result_map[b.id] = b
						}
					}
				}
				mut results := []ContentBlock{}
				for id in tool_use_ids {
					if id in tool_result_map {
						results << tool_result_map[id]
					} else {
						results << ContentBlock{
							typ:      'tool_result'
							id:       id
							content:  '[Operation interrupted by user]'
							is_error: true
						}
					}
				}
				final_messages << NormalizedMessage{
					role:   'user'
					blocks: results
				}
			}
		} else {
			mut non_tool_results := []ContentBlock{}
			for b in msg.blocks {
				if b.typ != 'tool_result' {
					non_tool_results << b
				}
			}
			if non_tool_results.len > 0 {
				final_messages << NormalizedMessage{
					role:   'user'
					blocks: non_tool_results
				}
			}
		}
	}

	if final_messages.len > 0 && final_messages[0].role != 'user' {
		mut with_user := [
			NormalizedMessage{
				role:   'user'
				blocks: [ContentBlock{
					typ:  'text'
					text: 'Hello'
				}]
			},
		]
		for m in final_messages {
			with_user << m
		}
		final_messages = with_user.clone()
	}

	mut parts := []string{}
	for m in final_messages {
		mut block_strings := []string{}
		for b in m.blocks {
			block_strings << build_content_block_json(b)
		}
		parts << '{"role":${json2.encode(m.role)},"content":[${block_strings.join(',')}]}'
	}

	return '[${parts.join(',')}]'
}

fn build_content_block_json(block ContentBlock) string {
	match block.typ {
		'text' {
			return '{"type":"text","text":${json2.encode(block.text)}}'
		}
		'tool_use' {
			clean_input := sanitize_tool_input_json(block.input)
			return '{"type":"tool_use","id":${json2.encode(block.id)},"name":${json2.encode(block.name)},"input":${clean_input}}'
		}
		'tool_result' {
			is_error_str := if block.is_error { 'true' } else { 'false' }
			if img := block.image_data {
				return '{"type":"tool_result","tool_use_id":${json2.encode(block.id)},"content":[{"type":"text","text":${json2.encode(block.content)}},{"type":"image","source":{"type":"base64","media_type":${json2.encode(img.mime_type)},"data":${json2.encode(img.data)}}}],"is_error":${is_error_str}}'
			}
			return '{"type":"tool_result","tool_use_id":${json2.encode(block.id)},"content":${json2.encode(block.content)},"is_error":${is_error_str}}'
		}
		else {
			return '{"type":"text","text":""}'
		}
	}
}

fn effort_to_budget(effort string, max_tokens int) int {
	return match effort {
		'low' {
			1024
		}
		'medium' {
			10000
		}
		'high' {
			50000
		}
		'max' {
			if max_tokens > 1 {
				max_tokens - 1
			} else {
				10000
			}
		}
		else {
			10000
		}
	}
}
