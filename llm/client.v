module llm

import net.http
import time
import config
import tools
import json

// Represents a content block in a message
pub struct ContentBlock {
pub mut:
	typ        string // "text", "tool_use", "tool_result"
	text       string // for text blocks
	id         string // for tool_use and tool_result
	name       string // for tool_use
	input      string // for tool_use (raw JSON string of input)
	content    string // for tool_result
	is_error   bool   // for tool_result
	image_data ?tools.ImageData // for tool_result with images
}

// A message in the conversation
pub struct Message {
pub mut:
	role    string
	content []ContentBlock
	text    string // simple text content (for user messages that are just text)
}

// Tool call parsed from LLM response
pub struct ToolCall {
pub:
	id    string
	name  string
	input string // raw JSON
}

// Result of a streaming chat call
pub struct StreamResult {
pub:
	text       string
	thinking   string
	tool_calls []ToolCall
}

pub type OnStreamText = fn (string)
pub type OnToolCall = fn (ToolCall)

@[heap]
pub struct Client {
pub mut:
	api_key        string
	api_url        string
	model          string
	max_tokens     int
	api_format     string // "anthropic" or "openai"
	effort         string // "low", "medium", "high", "max"
	thinking_format string // "", "openrouter", "zai"
	reasoning      bool   // whether model supports reasoning
	messages       []Message
	system_prompt  string
	tool_schemas   string // JSON string of tool schemas
	aborted        bool
	mcp_schemas_merged bool
	request_generation int // incremented each chat_stream to ignore stale chunks
}

pub fn new_client(cfg config.ResolvedConfig) Client {
	schemas := if cfg.api_format == 'openai' { tools.get_schemas_openai() } else { tools.get_schemas() }
	return Client{
		api_key: cfg.api_key
		api_url: cfg.api_url
		model: cfg.model
		max_tokens: cfg.max_tokens
		api_format: cfg.api_format
		effort: cfg.effort
		thinking_format: cfg.thinking_format
		reasoning: cfg.reasoning
		system_prompt: 'You are a helpful coding assistant.'
		tool_schemas: schemas
	}
}

// reconfigure updates the client with a new resolved config, preserving message history
pub fn (mut c Client) reconfigure(cfg config.ResolvedConfig) {
	c.api_key = cfg.api_key
	c.api_url = cfg.api_url
	c.model = cfg.model
	c.max_tokens = cfg.max_tokens
	c.api_format = cfg.api_format
	c.effort = cfg.effort
	c.thinking_format = cfg.thinking_format
	c.reasoning = cfg.reasoning
	c.tool_schemas = if cfg.api_format == 'openai' { tools.get_schemas_openai() } else { tools.get_schemas() }
}

pub fn (mut c Client) merge_mcp_schemas(mcp_schemas string) {
	if mcp_schemas.len == 0 || c.mcp_schemas_merged {
		return
	}
	c.tool_schemas = tools.merge_schemas(c.tool_schemas, mcp_schemas)
	c.mcp_schemas_merged = true
}

// chat_stream sends a streaming request to the LLM API.
// If prompt is non-empty, it is added as a user message first.
// When continuing after tool results, pass '' as prompt.
pub fn (mut c Client) chat_stream(prompt string, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText) !StreamResult {
	// Reset abort flag for this request and bump generation to ignore stale chunks
	c.aborted = false
	c.request_generation++
	my_gen := c.request_generation
	if prompt.len > 0 {
		c.messages << Message{
			role: 'user'
			text: prompt
		}
	}

	body_json := if c.api_format == 'openai' {
		c.build_request_body_openai()
	} else {
		c.build_request_body_anthropic()
	}

	// Debug: write request body to log file
	// os.write_file('wink-code-debug.log', body_json) or {}

	mut headers := http.new_header()
	if c.api_format == 'openai' {
		headers.add_custom('Authorization', 'Bearer ${c.api_key}') or {}
	} else {
		headers.add_custom('x-api-key', c.api_key) or {}
		headers.add_custom('anthropic-version', '2023-06-01') or {}
	}
	headers.add_custom('content-type', 'application/json') or {}

	mut state := StreamState{
		api_format: c.api_format
		generation: my_gen
	}

	mut http_req := http.Request{
		method: .post
		url: c.api_url
		header: headers
		data: body_json
		read_timeout: 120 * time.second
		on_progress_body: fn [mut state, on_text, on_tool_call, on_thinking, mut c, my_gen] (mut request &http.Request, chunk []u8, body_so_far u64, body_expected u64, status_code int) ! {
			process_stream_chunk(mut request, mut state, chunk, body_so_far, body_expected, status_code, my_gen, mut c, on_text, on_tool_call, on_thinking)
		}
	}

	response := http_req.do() or { return error('API request failed: ${err}') }

	if response.status_code != 200 {
		return error('API error ${response.status_code}: ${response.body}')
	}

	// Fallback: Windows vschannel backend doesn't invoke on_progress_body.
	// Parse the full response body if streaming didn't work.
	if !state.streamed && response.body.len > 0 {
		mut sse_body := response.body
		// response.body may contain HTTP headers if vschannel didn't strip them
		// Find the first 'data:' line to start parsing
		if idx := sse_body.index('data:') {
			sse_body = sse_body[idx..]
		}
		parse_sse_full(mut state, sse_body, on_text, on_tool_call, on_thinking, my_gen)
	}

	// Finalize any pending tool call
	if state.pending_tool_id.len > 0 {
		tc := ToolCall{
			id: state.pending_tool_id
			name: state.pending_tool_name
			input: state.pending_tool_input
		}
		state.tool_calls << tc
		on_tool_call(tc)
		state.pending_tool_id = ''
		state.pending_tool_name = ''
		state.pending_tool_input = ''
	}

	// Add assistant message to history
	c.add_assistant_message(state.full_text, state.tool_calls)

	return StreamResult{
		text: state.full_text
		thinking: state.thinking
		tool_calls: state.tool_calls
	}
}

fn process_stream_chunk(mut request &http.Request, mut state StreamState, chunk []u8, body_so_far u64, body_expected u64, status_code int, my_gen int, mut c Client, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText) {
	if status_code != 200 {
		return
	}
	// Ignore chunks from previous requests (race condition when user sends
	// a new message before the old HTTP request fully finishes).
	if my_gen != c.request_generation {
		return
	}
	if c.aborted {
		// set stop_receiving_limit to 1 to break the HTTP read loop
		// on the next iteration. V's net.http checks:
		//   if req.stop_receiving_limit > 0 && new_len > req.stop_receiving_limit
		// So 1 is enough to trigger break after the next chunk arrives.
		request.stop_receiving_limit = 1
		return
	}
	state.streamed = true
	chunk_str := chunk.bytestr()
	state.buffer += chunk_str
	state.raw_body += chunk_str
	process_buffered_lines(mut state, on_text, on_tool_call, on_thinking)
}

// add_tool_results adds tool results as a user message (internal format)
pub fn (mut c Client) add_tool_results(results map[string]tools.ToolResult) {
	mut blocks := []ContentBlock{}
	for tool_use_id, result in results {
		blocks << ContentBlock{
			typ:      'tool_result'
			id:       tool_use_id
			content:  result.content
			is_error: result.is_error
			image_data: result.image_data
		}
	}
	c.messages << Message{
		role:    'user'
		content: blocks
	}
}

// add_user_message adds a simple user message
pub fn (mut c Client) add_user_message(text string) {
	c.messages << Message{
		role: 'user'
		text: text
	}
}

// add_assistant_message adds an assistant message with content blocks
pub fn (mut c Client) add_assistant_message(text string, tool_calls []ToolCall) {
	mut blocks := []ContentBlock{}
	if text.len > 0 {
		blocks << ContentBlock{
			typ: 'text'
			text: text
		}
	}
	for tc in tool_calls {
		blocks << ContentBlock{
			typ: 'tool_use'
			id: tc.id
			name: tc.name
			input: tc.input
		}
	}
	c.messages << Message{
		role: 'assistant'
		content: blocks
	}
}

pub fn (mut c Client) clear_messages() {
	c.messages = []Message{}
}

// --- Internal types ---

struct StreamState {
mut:
	buffer             string
	current_event      string // Anthropic SSE event type
	full_text          string
	thinking           string
	tool_calls         []ToolCall
	// Pending tool_use block being accumulated
	pending_tool_id    string
	pending_tool_name  string
	pending_tool_input string
	current_block_type string // "text", "tool_use", or "thinking" (Anthropic)
	api_format         string // "anthropic" or "openai"
	openai_done        bool   // OpenAI [DONE] signal
	raw_body           string // accumulated raw SSE data (for fallback)
	streamed           bool   // whether on_progress_body was ever called
	generation         int    // request generation, to ignore stale chunks
}

// --- Anthropic SSE handlers ---

fn handle_block_start(mut state StreamState, json_str string) {
	if json_str.contains('"tool_use"') {
		state.current_block_type = 'tool_use'
		state.pending_tool_id = extract_json_string_value(json_str, 'id')
		state.pending_tool_name = extract_json_string_value(json_str, 'name')
		state.pending_tool_input = ''
		return
	}
	// Anthropic thinking block: {"content_block":{"type":"thinking",...}}
	if json_str.contains('"type":"thinking"') {
		state.current_block_type = 'thinking'
		return
	}
	state.current_block_type = 'text'
}

fn handle_block_delta(mut state StreamState, json_str string, on_text OnStreamText, on_thinking OnStreamText) {
	if state.current_block_type == 'tool_use' {
		if json_str.contains('"input_json_delta"') {
			partial := extract_json_string_value(json_str, 'partial_json')
			state.pending_tool_input += partial
		}
	} else if state.current_block_type == 'thinking' {
		// Anthropic thinking_delta: {"delta":{"type":"thinking_delta","thinking":"..."}}
		if json_str.contains('"thinking_delta"') {
			thinking := extract_json_string_value(json_str, 'thinking')
			if thinking.len > 0 {
				state.thinking += thinking
				on_thinking(thinking)
			}
		}
	} else {
		if json_str.contains('"text_delta"') {
			text := extract_text_delta(json_str)
			if text.len > 0 {
				state.full_text += text
				on_text(text)
			}
		}
	}
}

fn handle_block_stop(mut state StreamState, on_tool_call OnToolCall) {
	if state.current_block_type == 'tool_use' && state.pending_tool_id.len > 0 {
		tc := ToolCall{
			id: state.pending_tool_id
			name: state.pending_tool_name
			input: state.pending_tool_input
		}
		state.tool_calls << tc
		on_tool_call(tc)
		state.pending_tool_id = ''
		state.pending_tool_name = ''
		state.pending_tool_input = ''
	}
	state.current_block_type = ''
}

// --- OpenAI SSE handler ---

fn handle_openai_delta(mut state StreamState, json_str string, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText) {
	// Extract reasoning/thinking content (OpenAI reasoning models, DeepSeek, etc.)
	// Formats: "reasoning_content":"..." or "reasoning":"..."
	if json_str.contains('"reasoning_content":"') {
		thinking := extract_json_string_value(json_str, 'reasoning_content')
		if thinking.len > 0 {
			state.thinking += thinking
			on_thinking(thinking)
		}
	} else if json_str.contains('"reasoning":"') {
		thinking := extract_json_string_value(json_str, 'reasoning')
		if thinking.len > 0 {
			state.thinking += thinking
			on_thinking(thinking)
		}
	}

	// Extract text content from delta
	if json_str.contains('"content":"') && !json_str.contains('"tool_calls"') {
		text := extract_json_string_value(json_str, 'content')
		if text.len > 0 {
			state.full_text += text
			on_text(text)
		}
	}

	// Extract tool calls from delta
	if json_str.contains('"tool_calls"') {
		// New tool call (has id and name)
		if json_str.contains('"id":"') && json_str.contains('"name":"') {
			// Finalize previous tool call if any
			if state.pending_tool_id.len > 0 {
				tc := ToolCall{
					id: state.pending_tool_id
					name: state.pending_tool_name
					input: state.pending_tool_input
				}
				state.tool_calls << tc
				on_tool_call(tc)
			}
			state.pending_tool_id = extract_json_string_value(json_str, 'id')
			state.pending_tool_name = extract_json_string_value(json_str, 'name')
			state.pending_tool_input = ''
		}

		// Arguments chunk
		if json_str.contains('"arguments":"') {
			args := extract_json_string_value(json_str, 'arguments')
			state.pending_tool_input += args
		}
	}

	// Check finish_reason for tool_calls
	if json_str.contains('"finish_reason":"tool_calls"') {
		if state.pending_tool_id.len > 0 {
			tc := ToolCall{
				id: state.pending_tool_id
				name: state.pending_tool_name
				input: state.pending_tool_input
			}
			state.tool_calls << tc
			on_tool_call(tc)
			state.pending_tool_id = ''
			state.pending_tool_name = ''
			state.pending_tool_input = ''
		}
	}
}

// --- SSE line processors ---

fn process_buffered_lines(mut state StreamState, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText) {
	for state.buffer.contains('\n') {
		nl_idx := state.buffer.index('\n') or { break }
		line := state.buffer[..nl_idx].trim_space()
		state.buffer = state.buffer[nl_idx + 1..]

		if state.api_format == 'anthropic' {
			process_anthropic_line(mut state, line, on_text, on_tool_call, on_thinking)
		} else {
			process_openai_line(mut state, line, on_text, on_tool_call, on_thinking)
		}
	}
}

fn process_anthropic_line(mut state StreamState, line string, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText) {
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
	event_type := state.current_event
	state.current_event = ''
	match event_type {
		'content_block_start' {
			handle_block_start(mut state, json_str)
		}
		'content_block_delta' {
			handle_block_delta(mut state, json_str, on_text, on_thinking)
		}
		'content_block_stop' {
			handle_block_stop(mut state, on_tool_call)
		}
		else {}
	}
}

fn process_openai_line(mut state StreamState, line string, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText) {
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
	handle_openai_delta(mut state, json_str, on_text, on_tool_call, on_thinking)
}

// --- JSON extraction helpers ---

// extract_text_delta pulls the text value from a text_delta JSON string (Anthropic)
fn extract_text_delta(json_str string) string {
	key := '"text":"'
	start_idx := json_str.index(key) or { return '' }
	after_key := json_str[start_idx + key.len..]
	end_idx := after_key.index('"') or { return '' }
	raw := after_key[..end_idx]
	return raw.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"').replace('\\\\',
		'\\')
}

// extract_json_string_value extracts a string value for a given key from JSON.
// Simple extraction - only works for flat string values, not nested objects.
fn extract_json_string_value(json_str string, key string) string {
	search := '"${key}":"'
	start_idx := json_str.index(search) or { return '' }
	after_key := json_str[start_idx + search.len..]
	// Find closing quote, handling escaped quotes
	mut i := 0
	mut result := []u8{}
	for i < after_key.len {
		ch := after_key[i]
		if ch == `\\` && i + 1 < after_key.len {
			next := after_key[i + 1]
			match next {
				`n` { result << `\n`.bytes() }
				`t` { result << `\t`.bytes() }
				`"` { result << `"` }
				`\\` { result << `\\` }
				else {
					result << ch
					result << next
				}
			}
			i += 2
			continue
		}
		if ch == `"` {
			break
		}
		result << ch
		i++
	}
	return result.bytestr()
}

// --- Fallback SSE parser (for Windows vschannel backend) ---

// parse_sse_full parses a complete SSE response body.
// Used when on_progress_body is not invoked (e.g. Windows vschannel SSL backend).
fn parse_sse_full(mut state StreamState, sse_body string, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText, my_gen int) {
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
			process_anthropic_line(mut state, trimmed, on_text, on_tool_call, on_thinking)
		} else {
			process_openai_line(mut state, trimmed, on_text, on_tool_call, on_thinking)
		}
	}
}

// --- Request body builders ---

struct ThinkingConfig {
	typ            string
	budget_tokens  int
}

fn (c &Client) build_request_body_anthropic() string {
	mut max_tokens := c.max_tokens
	mut thinking_json := ''
	if c.reasoning && c.effort.len > 0 {
		budget := effort_to_budget(c.effort, c.max_tokens)
		if budget >= max_tokens {
			max_tokens = budget + 4096
		}
		thinking_json = json.encode(ThinkingConfig{'enabled', budget})
	}

	mut fields := []string{}
	fields << '"model":${json.encode(c.model)}'
	fields << '"max_tokens":${max_tokens}'
	if thinking_json.len > 0 {
		fields << '"thinking":${thinking_json}'
	}
	fields << '"system":${json.encode(c.system_prompt)}'
	fields << '"messages":${build_anthropic_messages_json(c.messages)}'
	fields << '"tools":${c.tool_schemas}'
	fields << '"stream":true'
	return '{${fields.join(',')}}'
}

fn build_anthropic_messages_json(messages []Message) string {
	mut parts := []string{}
	for msg in messages {
		parts << build_anthropic_message_json(msg)
	}
	return '[${parts.join(',')}]'
}

fn build_anthropic_message_json(msg Message) string {
	if msg.content.len == 0 && msg.text.len > 0 {
		return '{"role":${json.encode(msg.role)},"content":${json.encode(msg.text)}}'
	} else if msg.content.len > 0 {
		mut blocks := []string{}
		for block in msg.content {
			blocks << build_content_block_json(block)
		}
		return '{"role":${json.encode(msg.role)},"content":[${blocks.join(',')}]}'
	} else {
		return '{"role":${json.encode(msg.role)},"content":""}'
	}
}

fn (c &Client) build_request_body_openai() string {
	mut fields := []string{}
	fields << '"model":${json.encode(c.model)}'
	fields << '"max_tokens":${c.max_tokens}'

	// Reasoning effort for reasoning models
	if c.reasoning && c.effort.len > 0 {
		effort_val := if c.effort == 'max' { 'high' } else { c.effort }
		fields << '"reasoning_effort":${json.encode(effort_val)}'
	}

	fields << '"messages":${build_openai_messages_json(c.messages, c.system_prompt)}'
	fields << '"tools":${c.tool_schemas}'
	fields << '"stream":true'
	return '{${fields.join(',')}}'
}

fn build_openai_messages_json(messages []Message, system_prompt string) string {
	mut parts := []string{}
	parts << '{"role":"system","content":${json.encode(system_prompt)}}'
	for msg in messages {
		if msg.role == 'user' && msg.content.len > 0 {
			tool_result_msgs := build_openai_tool_result_messages(msg)
			for tool_msg in tool_result_msgs {
				parts << tool_msg
			}
			continue
		}
		parts << build_openai_message_json(msg)
	}
	return '[${parts.join(',')}]'
}

fn build_openai_message_json(msg Message) string {
	if msg.content.len == 0 && msg.text.len > 0 {
		return '{"role":${json.encode(msg.role)},"content":${json.encode(msg.text)}}'
	} else if msg.role == 'assistant' && msg.content.len > 0 {
		mut text_content := ''
		mut tool_calls_json := []string{}
		for block in msg.content {
			match block.typ {
				'text' { text_content = block.text }
				'tool_use' {
					tool_calls_json << '{"id":${json.encode(block.id)},"type":"function","function":{"name":${json.encode(block.name)},"arguments":${json.encode(block.input)}}}'
				}
				else {}
			}
		}
		mut msg_parts := []string{}
		msg_parts << '"role":${json.encode("assistant")}'
		if text_content.len > 0 {
			msg_parts << '"content":${json.encode(text_content)}'
		} else {
			msg_parts << '"content":null'
		}
		if tool_calls_json.len > 0 {
			msg_parts << '"tool_calls":[${tool_calls_json.join(',')}]'
		}
		return '{${msg_parts.join(',')}}'
	} else {
		return '{"role":${json.encode(msg.role)},"content":""}'
	}
}

fn build_openai_tool_result_messages(msg Message) []string {
	mut result := []string{}
	for block in msg.content {
		if block.typ != 'tool_result' {
			continue
		}
		if img := block.image_data {
			// Multimodal tool result with image
			data_url := 'data:${img.mime_type};base64,${img.data}'
			result << '{"role":"tool","tool_call_id":${json.encode(block.id)},"content":[{"type":"text","text":${json.encode(block.content)}},{"type":"image_url","image_url":{"url":${json.encode(data_url)}}}]}'
		} else {
			result << '{"role":"tool","tool_call_id":${json.encode(block.id)},"content":${json.encode(block.content)}}'
		}
	}
	return result
}

fn build_content_block_json(block ContentBlock) string {
	match block.typ {
		'text' {
			return '{"type":"text","text":${json.encode(block.text)}}'
		}
		'tool_use' {
			return '{"type":"tool_use","id":${json.encode(block.id)},"name":${json.encode(block.name)},"input":${block.input}}'
		}
		'tool_result' {
			is_error_str := if block.is_error { 'true' } else { 'false' }
			if img := block.image_data {
				// Multimodal tool result with image
				data_url := 'data:${img.mime_type};base64,${img.data}'
				return '{"type":"tool_result","tool_use_id":${json.encode(block.id)},"content":[{"type":"text","text":${json.encode(block.content)}},{"type":"image_url","image_url":{"url":${json.encode(data_url)}}}],"is_error":${is_error_str}}'
			}
			return '{"type":"tool_result","tool_use_id":${json.encode(block.id)},"content":${json.encode(block.content)},"is_error":${is_error_str}}'
		}
		else {
			return '{"type":"text","text":""}'
		}
	}
}

fn effort_to_budget(effort string, max_tokens int) int {
	return match effort {
		'low' { 1024 }
		'medium' { 10000 }
		'high' { 50000 }
		'max' { if max_tokens > 1 { max_tokens - 1 } else { 10000 } }
		else { 10000 }
	}
}
