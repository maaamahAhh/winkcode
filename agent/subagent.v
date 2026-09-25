module agent

import strings
import tools

fn subagent_schema_anthropic() string {
	return '[{"name":"subagent","description":"Execute a task in an isolated agent session and return the final output","input_schema":{"type":"object","properties":{"prompt":{"type":"string","description":"The prompt or instructions to execute"},"read_only":{"type":"boolean","description":"Optional. If true, only allows reading and searching files (no edits or shell commands)"}},"required":["prompt"]}}]'
}

fn subagent_schema_openai() string {
	return '[{"type":"function","function":{"name":"subagent","description":"Execute a task in an isolated agent session and return the final output","parameters":{"type":"object","properties":{"prompt":{"type":"string","description":"The prompt or instructions to execute"},"read_only":{"type":"boolean","description":"Optional. If true, only allows reading and searching files (no edits or shell commands)"}},"required":["prompt"]}}}]'
}

// subagent_schema returns the tool schema JSON string for the subagent tool.
pub fn subagent_schema(api_format string) string {
	if api_format == 'openai' {
		return subagent_schema_openai()
	}
	return subagent_schema_anthropic()
}

struct SubagentContext {
mut:
	buf_ref          &strings.Builder
	parent_cb        AgentCallbacks
	subagent_call_id string
}

fn subagent_on_text(user_data voidptr, text string) {
	mut ctx := unsafe { &SubagentContext(user_data) }
	unsafe { ctx.buf_ref.write_string(text) }
}

fn subagent_on_thinking(_user_data voidptr, _text string) {}

fn subagent_on_tool_call(user_data voidptr, call_id string, name string, input string, display_title string, _parent_id string) {
	mut ctx := unsafe { &SubagentContext(user_data) }
	if ctx.parent_cb.on_tool_call != unsafe { nil } {
		title := if display_title.len > 0 { display_title } else { name }
		ctx.parent_cb.on_tool_call(ctx.parent_cb.user_data, call_id, name, input, 'subagent > ${title}', ctx.subagent_call_id)
	}
}

fn subagent_on_tool_stream(_user_data voidptr, _name string, _args string) {}

fn subagent_on_tool_result(user_data voidptr, call_id string, name string, preview string, is_error bool, _parent_id string) {
	mut ctx := unsafe { &SubagentContext(user_data) }
	if ctx.parent_cb.on_tool_result != unsafe { nil } {
		ctx.parent_cb.on_tool_result(ctx.parent_cb.user_data, call_id, name, preview, is_error, ctx.subagent_call_id)
	}
}

fn subagent_on_complete(_user_data voidptr) {}

fn subagent_on_error(user_data voidptr, msg string) {
	mut ctx := unsafe { &SubagentContext(user_data) }
	unsafe { ctx.buf_ref.writeln('\n[Subagent Error: ${msg}]') }
}

// run_subagent executes an isolated child agent session and returns its final textual result.
fn (a &Agent) run_subagent(subagent_call_id string, prompt string, read_only bool, parent_cb AgentCallbacks) tools.ToolResult {
	if prompt.trim_space().len == 0 {
		return tools.ToolResult{
			content:  'Error: prompt is required for subagent'
			is_error: true
		}
	}

	mut sub_client := a.client.clone_clean()

	mut final_buf := strings.new_builder(4096)
	mut sub_ctx := SubagentContext{
		buf_ref:          &final_buf
		parent_cb:        parent_cb
		subagent_call_id: subagent_call_id
	}
	sub_cb := AgentCallbacks{
		user_data:      voidptr(&sub_ctx)
		on_text:        subagent_on_text
		on_thinking:    subagent_on_thinking
		on_tool_call:   subagent_on_tool_call
		on_tool_stream: subagent_on_tool_stream
		on_tool_result: subagent_on_tool_result
		on_complete:    subagent_on_complete
		on_error:       subagent_on_error
	}

	mut sub_agent := Agent{
		config:      a.config
		client:      sub_client
		mcp_manager: a.mcp_manager
		max_turns:   a.max_turns
		is_subagent: true
		read_only:   read_only
	}

	sub_agent.run(prompt, sub_cb)

	res_text := final_buf.str().trim_space()
	return tools.ToolResult{
		content:  if res_text.len > 0 {
			res_text
		} else {
			'Subagent completed task with no text output.'
		}
		is_error: false
	}
}
