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
	mut buf_ref := &final_buf
	sub_cb := AgentCallbacks{
		on_text:        fn [mut buf_ref] (text string) {
			unsafe { buf_ref.write_string(text) }
		}
		on_thinking:    fn (_text string) {}
		on_tool_call:   fn [parent_cb, subagent_call_id] (call_id string, name string, input string, display_title string, _parent_id string) {
			if parent_cb.on_tool_call != unsafe { nil } {
				title := if display_title.len > 0 { display_title } else { name }
				parent_cb.on_tool_call(call_id, name, input, 'subagent > ${title}', subagent_call_id)
			}
		}
		on_tool_stream: fn (_name string, _args string) {}
		on_tool_result: fn [parent_cb, subagent_call_id] (call_id string, name string, preview string, is_error bool, _parent_id string) {
			if parent_cb.on_tool_result != unsafe { nil } {
				parent_cb.on_tool_result(call_id, name, preview, is_error, subagent_call_id)
			}
		}
		on_complete:    fn () {}
		on_error:       fn [mut buf_ref] (msg string) {
			unsafe { buf_ref.writeln('\n[Subagent Error: ${msg}]') }
		}
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
