module llm

import net.http

struct PendingToolCall {
mut:
	id        string
	name      string
	arguments string
}

struct StreamState {
mut:
	buffer             string
	current_event      string // Anthropic SSE event type
	full_text          string
	thinking           string
	reasoning_field    string // reasoning field name received ("reasoning_content" or "reasoning")
	processed_bytes    int    // bytes already appended, for http/1.1 accumulated-chunk semantics
	tool_call_seq      int    // counter for unique tool call ids
	tool_calls         []ToolCall
	pending_tool_id    string
	pending_tool_name  string
	pending_tool_input string
	pending_tools      []PendingToolCall // OpenAI tool calls accumulated by index
	current_block_type string            // "text", "tool_use", or "thinking" (Anthropic)
	api_format         string            // "anthropic" or "openai"
	openai_done        bool              // OpenAI [DONE] signal
	raw_body           string            // accumulated raw SSE data (for fallback)
	streamed           bool              // whether on_progress_body was ever called
	generation         int               // request generation, to ignore stale chunks
}

fn process_stream_chunk(mut request http.Request, mut state StreamState, chunk []u8, body_so_far u64, _body_expected u64, status_code int, my_gen int, mut c Client, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText, on_tool_stream OnToolStream) {
	if status_code != 200 {
		return
	}
	if my_gen != c.request_generation {
		return
	}
	if c.aborted {
		request.stop_receiving_limit = 1
		return
	}
	state.streamed = true
	chunk_str := chunk.bytestr()
	if u64(chunk_str.len) >= body_so_far && state.processed_bytes < chunk_str.len {
		state.buffer += chunk_str[state.processed_bytes..]
		state.processed_bytes = chunk_str.len
		state.raw_body = chunk_str
	} else {
		state.buffer += chunk_str
		state.raw_body += chunk_str
	}
	process_buffered_lines(mut state, on_text, on_tool_call, on_thinking, on_tool_stream)
}

fn process_buffered_lines(mut state StreamState, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText, on_tool_stream OnToolStream) {
	for state.buffer.contains('\n') {
		nl_idx := state.buffer.index('\n') or { break }
		line := state.buffer[..nl_idx].trim_space()
		state.buffer = state.buffer[nl_idx + 1..]

		if state.api_format == 'anthropic' {
			process_anthropic_line(mut state, line, on_text, on_tool_call, on_thinking,
				on_tool_stream)
		} else {
			process_openai_line(mut state, line, on_text, on_tool_call, on_thinking, on_tool_stream)
		}
	}
}

// parse_sse_full parses a complete SSE response body.
// Used when on_progress_body is not invoked (e.g. Windows vschannel SSL backend).
fn parse_sse_full(mut state StreamState, sse_body string, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText, on_tool_stream OnToolStream, my_gen int) {
	if my_gen != state.generation {
		return
	}
	lines := sse_body.split('\n')
	for line in lines {
		trimmed := line.trim_space()
		if trimmed.len == 0 {
			state.current_event = ''
			continue
		}
		if state.api_format == 'anthropic' {
			process_anthropic_line(mut state, trimmed, on_text, on_tool_call, on_thinking,
				on_tool_stream)
		} else {
			process_openai_line(mut state, trimmed, on_text, on_tool_call, on_thinking,
				on_tool_stream)
		}
	}
}
