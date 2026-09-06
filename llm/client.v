module llm

import net.http
import time
import config
import tools
import json2
import utils

// Represents a content block in a message
pub struct ContentBlock {
pub mut:
	typ        string           // "text", "tool_use", "tool_result"
	text       string           // for text blocks
	id         string           // for tool_use and tool_result
	name       string           // for tool_use
	input      string           // for tool_use (raw JSON string of input)
	content    string           // for tool_result
	is_error   bool             // for tool_result
	image_data ?tools.ImageData // for tool_result with images
}

// A message in the conversation
pub struct Message {
pub mut:
	role           string
	content        []ContentBlock
	text           string // simple text content (for user messages that are just text)
	thinking       string // assistant reasoning content
	thinking_field string // reasoning field name to echo back ("reasoning_content" or "reasoning")
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

pub type OnToolStream = fn (string, string)

pub type OnToolCall = fn (ToolCall)

@[heap]
pub struct Client {
pub mut:
	api_key            string
	api_url            string
	model              string
	max_tokens         int
	context_window     int
	api_format         string // "anthropic" or "openai"
	effort             string // "low", "medium", "high", "max"
	thinking_format    string // "", "openrouter", "zai"
	reasoning          bool   // whether model supports reasoning
	messages           []Message
	system_prompt      string
	tool_schemas       string // JSON string of tool schemas
	aborted            bool
	mcp_schemas_merged bool
	request_generation int // incremented each chat_stream to ignore stale chunks
}

pub fn new_client(cfg config.ResolvedConfig) Client {
	schemas := if cfg.api_format == 'openai' {
		tools.get_schemas_openai()
	} else {
		tools.get_schemas()
	}
	return Client{
		api_key:         cfg.api_key
		api_url:         cfg.api_url
		model:           cfg.model
		max_tokens:      cfg.max_tokens
		context_window:  cfg.context_window
		api_format:      cfg.api_format
		effort:          cfg.effort
		thinking_format: cfg.thinking_format
		reasoning:       cfg.reasoning
		system_prompt:   'You are a helpful coding assistant.'
		tool_schemas:    schemas
	}
}

// clone_clean creates an independent Client copy with empty conversation history for subagents.
pub fn (c &Client) clone_clean() Client {
	return Client{
		api_key:         c.api_key
		api_url:         c.api_url
		model:           c.model
		max_tokens:      c.max_tokens
		context_window:  c.context_window
		api_format:      c.api_format
		effort:          c.effort
		thinking_format: c.thinking_format
		reasoning:       c.reasoning
		system_prompt:   c.system_prompt
		messages:        []Message{}
	}
}

// reconfigure updates the client with a new resolved config, preserving message history
pub fn (mut c Client) reconfigure(cfg config.ResolvedConfig) {
	c.api_key = cfg.api_key
	c.api_url = cfg.api_url
	c.model = cfg.model
	c.max_tokens = cfg.max_tokens
	c.context_window = cfg.context_window
	c.api_format = cfg.api_format
	c.effort = cfg.effort
	c.thinking_format = cfg.thinking_format
	c.reasoning = cfg.reasoning
	c.tool_schemas = if cfg.api_format == 'openai' {
		tools.get_schemas_openai()
	} else {
		tools.get_schemas()
	}
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
pub fn (mut c Client) chat_stream(prompt string, on_text OnStreamText, on_tool_call OnToolCall, on_thinking OnStreamText, on_tool_stream OnToolStream) !StreamResult {
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

	mut headers := http.new_header()

	if c.api_format == 'openai' {
		headers.add_custom('Authorization', 'Bearer ${c.api_key}') or {}
	} else {
		headers.add_custom('x-api-key', c.api_key) or {}
		headers.add_custom('anthropic-version', '2023-06-01') or {}
	}
	headers.add_custom('content-type', 'application/json') or {}
	headers.add_custom('User-Agent', 'winkcode/0.0.1.5') or {}

	mut state := StreamState{
		api_format: c.api_format
		generation: my_gen
	}
	// V closures capture `mut` structs by value, so the streamed flag set
	// inside the callback would never reach `state` below, causing the
	// fallback parser to run again (duplicated output). Capture a pointer
	// instead to share the state with the callback.
	mut state_ref := &state

	mut http_req := http.Request{
		method:           .post
		url:              c.api_url
		header:           headers
		data:             body_json
		read_timeout:     120 * time.second
		on_progress_body: fn [mut state_ref, on_text, on_tool_call, on_thinking, on_tool_stream, mut c, my_gen] (mut request http.Request, chunk []u8, body_so_far u64, body_expected u64, status_code int) ! {
			process_stream_chunk(mut request, mut state_ref, chunk, body_so_far, body_expected,
				status_code, my_gen, mut c, on_text, on_tool_call, on_thinking, on_tool_stream)
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
		parse_sse_full(mut state, sse_body, on_text, on_tool_call, on_thinking, on_tool_stream,
			my_gen)
	}

	// Finalize any pending tool call
	if state.pending_tool_id.len > 0 {
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
	finalize_openai_tool_calls(mut state, on_tool_call)

	// Add assistant message to history
	c.add_assistant_message(state.full_text, state.thinking, state.reasoning_field,
		state.tool_calls)

	return StreamResult{
		text:       state.full_text
		thinking:   state.thinking
		tool_calls: state.tool_calls
	}
}


pub fn (mut c Client) add_tool_results(results map[string]tools.ToolResult) {
	mut blocks := []ContentBlock{}
	for tool_use_id, result in results {
		blocks << ContentBlock{
			typ:        'tool_result'
			id:         tool_use_id
			content:    result.content
			is_error:   result.is_error
			image_data: result.image_data
		}
	}
	c.messages << Message{
		role:    'user'
		content: blocks
	}
}

pub fn (mut c Client) add_user_message(text string) {
	c.messages << Message{
		role: 'user'
		text: text
	}
}

pub fn (mut c Client) add_assistant_message(text string, thinking string, thinking_field string, tool_calls []ToolCall) {
	mut blocks := []ContentBlock{}
	if text.len > 0 {
		blocks << ContentBlock{
			typ:  'text'
			text: text
		}
	}
	for tc in tool_calls {
		blocks << ContentBlock{
			typ:   'tool_use'
			id:    tc.id
			name:  tc.name
			input: tc.input
		}
	}
	c.messages << Message{
		role:           'assistant'
		content:        blocks
		thinking:       thinking
		thinking_field: thinking_field
	}
}

pub fn (mut c Client) clear_messages() {
	c.messages = []Message{}
}

// sanitize_tool_input_json normalizes and escapes JSON arguments for standard RFC 8259 compliance.
fn sanitize_tool_input_json(raw string) string {
	s := raw.trim_space()
	if s.len == 0 {
		return '{}'
	}
	repaired := utils.repair_json(s)
	// Normalize through JSON object decoding and re-encoding (like JSON.stringify in pi)
	// to ensure all escape sequences (like Windows backslashes) are 100% standard RFC 8259 compliant.
	if obj := json2.decode[map[string]json2.Any](repaired) {
		return json2.encode(obj)
	}
	if flat := utils.parse_flat_json(s) {
		return json2.encode(flat)
	}
	return repaired
}
