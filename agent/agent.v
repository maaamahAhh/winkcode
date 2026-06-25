module agent

import llm
import tools
import config
import os
import skill
import compact
import utils
import mcp

pub struct AgentCallbacks {
pub:
	on_text        fn (string) = unsafe { nil }               // streaming text callback
	on_thinking    fn (string) = unsafe { nil }               // streaming thinking callback
	on_tool_call   fn (string, string) = unsafe { nil }       // tool name, status
	on_tool_result fn (string, string, bool) = unsafe { nil } // tool name, result preview, is_error
	on_complete    fn () = unsafe { nil }                     // agent turn complete
	on_error       fn (string) = unsafe { nil }               // error message
}

pub struct Agent {
pub mut:
	config       config.Config
	client       llm.Client
	max_turns    int = 20
	mcp_manager  mcp.McpManager
	aborted      bool
}

fn build_system_prompt() string {
	cwd := os.getwd()
	mut parts := [base_prompt(cwd)]
	parts << load_global_context()
	parts << load_project_context(cwd)
	skills := skill.load_skills(cwd)
	skills_str := skill.format_skills_for_prompt(skills)
	if skills_str.len > 0 {
		parts << skills_str
	}
	return parts.join('\n\n')
}

fn base_prompt(cwd string) string {
	return 'You are Wink Code, an expert coding assistant. You help users by reading files, executing commands, editing code, and writing new files.

Guidelines:
- Read files before editing them
- Do not create unnecessary files
- Prefer dedicated tools (read, grep, glob) over bash for file operations
- Be concise in your responses
- Show file paths clearly when working with files

Working directory: ${cwd}'
}

fn load_global_context() string {
	home := os.home_dir()
	if home.len == 0 {
		return ''
	}
	global_path := os.join_path(home, '.winkcode', 'AGENTS.md')
	if !os.exists(global_path) {
		return ''
	}
	content := os.read_file(global_path) or { '' }
	if content.len == 0 {
		return ''
	}
	return '# Global Context (~/.winkcode/AGENTS.md)\n\n${content}'
}

fn load_project_context(cwd string) string {
	mut current_dir := cwd
	mut closest_path := ''
	mut closest_content := ''
	for {
		for filename in ['AGENTS.md', 'CLAUDE.md'] {
			file_path := os.join_path(current_dir, filename)
			if os.exists(file_path) {
				content := os.read_file(file_path) or { '' }
				if content.len > 0 {
					closest_path = file_path
					closest_content = content
				}
			}
		}
		parent := os.join_path(current_dir, '..')
		abs_parent := os.real_path(parent)
		if abs_parent == current_dir {
			break
		}
		current_dir = abs_parent
	}
	if closest_content.len == 0 {
		return ''
	}
	return '# Project Context (${closest_path})\n\n${closest_content}'
}

pub fn new_agent(cfg config.Config) Agent {
	resolved := cfg.resolve() or {
		// This shouldn't happen if main.v validated the config
		panic('failed to resolve config: ${err}')
	}
	mut client := llm.new_client(resolved)
	client.system_prompt = build_system_prompt()

	// Load MCP config and initialize manager
	mut manager := mcp.new_mcp_manager()
	cwd := os.getwd()
	for mcp_cfg in mcp.load_mcp_config(cwd) {
		manager.add_server(mcp_cfg.name, mcp_cfg.command, mcp_cfg.args, mcp_cfg.env)
	}

	return Agent{
		config: cfg
		client: client
		mcp_manager: manager
	}
}

pub fn (a &Agent) get_model() string {
	return a.client.model
}

pub fn (a &Agent) get_effort() string {
	return a.client.effort
}

pub fn (a &Agent) get_model_provider(name string) string {
	return a.config.get_model_provider(name)
}

pub fn (a &Agent) get_model_names() []string {
	return a.config.get_model_names()
}

pub fn (mut a Agent) set_model(name string) ! {
	// Validate and set
	a.config.set_model(name)!
	// Try to resolve — revert on failure
	resolved := a.config.resolve() or {
		a.config.current_model = a.client.model
		return error('cannot switch model: ${err}')
	}
	a.client.reconfigure(resolved)
}

pub fn (mut a Agent) set_effort(level string) ! {
	old_effort := a.config.effort
	a.config.set_effort(level)!
	resolved := a.config.resolve() or {
		a.config.effort = old_effort
		return error('cannot set effort: ${err}')
	}
	a.client.reconfigure(resolved)
}

pub fn (mut a Agent) clear_conversation() {
	a.client.clear_messages()
}

// run executes the agent loop: send prompt, handle tool calls, repeat until done
pub fn (mut a Agent) run(prompt string, cb AgentCallbacks) {
	// Reset abort flag for this run
	a.client.aborted = false
	// Rebuild tool schemas from scratch each run to avoid corruption
	builtin_schemas := if a.client.api_format == 'openai' { tools.get_schemas_openai() } else { tools.get_schemas() }
	mcp_schemas := a.mcp_manager.get_tool_schemas(a.client.api_format)
	a.client.tool_schemas = tools.merge_schemas(builtin_schemas, mcp_schemas)

	mut current_prompt := prompt

	for turn := 0; turn < a.max_turns; turn++ {
		// Auto-compact if conversation is getting too long
		compact.compact(mut a.client) or {}

		result := a.client.chat_stream(current_prompt, cb.on_text, fn [cb] (tc llm.ToolCall) {
			cb.on_tool_call(tc.name, 'calling ${tc.name}...')
		}, cb.on_thinking) or {
			// Surface API errors as assistant messages (like claude-code does)
			// instead of raw error banners, so the conversation stays valid.
			err_msg := err.str()
			if err_msg.contains('API error') {
				cb.on_text('(API error: ${err_msg})')
			} else {
				cb.on_text('(Error: ${err_msg})')
			}
			cb.on_complete()
			return
		}

		if a.client.aborted {
			a.client.add_user_message('[Request interrupted by user]')
			cb.on_complete()
			return
		}

		if result.tool_calls.len == 0 {
			cb.on_complete()
			return
		}

		// Execute tool calls and collect results
		mut tool_results := map[string]tools.ToolResult{}

		for tc in result.tool_calls {
			args := parse_tool_input(tc.input)
			cb.on_tool_call(tc.name, 'running ${tc.name}...')

			// Try MCP first; only fallback to built-in tools if not an MCP tool
			mut tool_result := tools.ToolResult{}
			if _ := a.mcp_manager.find_tool(tc.name) {
				// MCP tools: pass raw JSON to preserve types (bool, number, etc.)
				mut mcp_args := tc.input.trim_space()
				if !(mcp_args.starts_with('{') && mcp_args.ends_with('}')) {
					mcp_args = '{}'
				}
				if mcp_result := a.mcp_manager.call_tool(tc.name, mcp_args) {
					mut tr := tools.ToolResult{
						content: mcp_result.text
						is_error: false
					}
					if mcp_result.images.len > 0 {
						img := mcp_result.images[0]
						if img.data.len > 0 {
							tr = tools.ToolResult{
								content: mcp_result.text
								is_error: false
								image_data: tools.ImageData{
									data: img.data
									mime_type: if img.mime_type.len > 0 { img.mime_type } else { 'image/png' }
									name: if img.name.len > 0 { img.name } else { 'screenshot' }
								}
							}
						}
					}
					tool_result = tr
				} else {
					// MCP tool failed; surface the error without falling back to built-in tools
					tool_result = tools.ToolResult{
						content: 'MCP tool "${tc.name}" failed: ${err.str()}'
						is_error: true
					}
				}
			} else {
				tool_result = tools.execute_tool(tc.name, args)
			}

			// Show preview of result
			preview := if tool_result.content.len > 200 {
				tool_result.content[..200] + '...'
			} else {
				tool_result.content
			}
			cb.on_tool_result(tc.name, preview, tool_result.is_error)

			tool_results[tc.id] = tool_result
		}

		// Add tool results to conversation
		a.client.add_tool_results(tool_results)

		// Next iteration continues with empty prompt (messages already in history)
		current_prompt = ''
	}

	cb.on_error('max turns reached (${a.max_turns})')
}

// parse_tool_input parses a JSON string into a map[string]string.
// The LLM sends tool input as a JSON object like {"path": "main.v"}.
// We flatten all values to strings.
fn parse_tool_input(input string) map[string]string {
	mut s := input.trim_space()
	if s.starts_with('{') && s.ends_with('}') {
		s = s[1..s.len - 1].trim_space()
	}
	return utils.parse_flat_json(s) or { map[string]string{} }
}
