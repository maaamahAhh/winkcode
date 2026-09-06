module agent

import llm
import tools
import config
import os
import skill
import compact
import mcp
import utils
import time
import sync

pub struct AgentCallbacks {
pub:
	on_text        fn (string)                               = unsafe { nil } // streaming text callback
	on_thinking    fn (string)                               = unsafe { nil } // streaming thinking callback
	on_tool_call   fn (string, string, string, string, string)       = unsafe { nil } // call_id, name, input, display_title, parent_id
	on_tool_stream fn (string, string)                       = unsafe { nil } // tool name, streaming arguments
	on_tool_result fn (string, string, string, bool, string) = unsafe { nil } // call_id, name, result preview, is_error, parent_id
	on_retry       fn (int, int, int, string)                = unsafe { nil } // attempt, max_attempts, delay_s, err_msg
	on_complete    fn ()                                     = unsafe { nil } // agent turn complete
	on_error       fn (string)                               = unsafe { nil } // error message
}

pub struct Agent {
pub mut:
	config      config.Config
	client      llm.Client
	max_turns   int = 100
	mcp_manager &mcp.McpManager = unsafe { nil }
	aborted     bool
	is_subagent bool
	read_only   bool
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

pub fn new_agent(cfg config.Config) !Agent {
	resolved := cfg.resolve() or {
		return error('failed to resolve config: ${err}')
	}
	mut client := llm.new_client(resolved)
	client.system_prompt = build_system_prompt()

	mut manager := &mcp.McpManager{
		servers: []&mcp.McpServer{}
		mu:      sync.new_mutex()
	}
	cwd := os.getwd()
	for mcp_cfg in mcp.load_mcp_config(cwd) {
		manager.add_server(mcp_cfg.name, mcp_cfg.command, mcp_cfg.args, mcp_cfg.env)
	}

	return Agent{
		config:      cfg
		client:      client
		mcp_manager: manager
	}
}

pub fn (a &Agent) get_model() string {
	return a.client.model
}

pub fn (a &Agent) get_effort() string {
	return a.client.effort
}

pub fn (a &Agent) get_context_tokens() int {
	return compact.estimate_tokens(a.client.messages)
}

pub fn (a &Agent) get_context_window() int {
	return if a.client.context_window > 0 { a.client.context_window } else { 256_000 }
}

pub fn (a &Agent) get_model_provider(name string) string {
	return a.config.get_model_provider(name)
}

pub fn (a &Agent) get_model_names() []string {
	return a.config.get_model_names()
}

pub fn (mut a Agent) set_model(name string) ! {
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

fn is_retryable_api_error(err_str string) bool {
	// Non-retryable: authentication or invalid client request
	if err_str.contains('401') || err_str.contains('403') || err_str.contains('Invalid API key')
		|| err_str.contains('authentication_error') {
		return false
	}
	// Retryable: Rate limits, server overloads, gateway errors, network timeouts
	if err_str.contains('429') || err_str.contains('500') || err_str.contains('502')
		|| err_str.contains('503') || err_str.contains('504') || err_str.contains('520')
		|| err_str.contains('521') || err_str.contains('522') || err_str.contains('524')
		|| err_str.contains('overloaded') || err_str.contains('rate_limit')
		|| err_str.contains('timeout') || err_str.contains('timed out')
		|| err_str.contains('connection') || err_str.contains('connect failed')
		|| err_str.contains('EOF') || err_str.contains('reset by peer')
		|| err_str.contains('ResourceExhausted') {
		return true
	}
	if err_str.starts_with('API request failed:') {
		return true
	}
	return false
}

fn (mut a Agent) prepare_tool_schemas() {
	if a.is_subagent {
		builtin_schemas := if a.client.api_format == 'openai' {
			tools.get_subagent_schemas_openai(a.read_only)
		} else {
			tools.get_subagent_schemas(a.read_only)
		}
		mcp_schemas := if a.read_only || a.mcp_manager == unsafe { nil } {
			''
		} else {
			a.mcp_manager.get_tool_schemas(a.client.api_format)
		}
		a.client.tool_schemas = tools.merge_schemas(builtin_schemas, mcp_schemas)
		return
	}
	builtin_schemas := if a.client.api_format == 'openai' {
		tools.get_schemas_openai()
	} else {
		tools.get_schemas()
	}
	sub_schema := subagent_schema(a.client.api_format)
	mcp_schemas := if a.mcp_manager != unsafe { nil } {
		a.mcp_manager.get_tool_schemas(a.client.api_format)
	} else {
		''
	}
	a.client.tool_schemas = tools.merge_schemas(tools.merge_schemas(builtin_schemas, sub_schema), mcp_schemas)
}

fn format_tool_display_title(name string, args map[string]string) string {
	return match name {
		'write' {
			if args['path'] != '' { 'write ${args['path']}' } else { name }
		}
		'read' {
			if args['path'] != '' { 'read ${args['path']}' } else { name }
		}
		'edit' {
			if args['path'] != '' { 'edit ${args['path']}' } else { name }
		}
		'bash' {
			if args['command'] != '' { 'bash ${args['command']}' } else { name }
		}
		'pwsh' {
			if args['command'] != '' { 'pwsh ${args['command']}' } else { name }
		}
		'cmd' {
			if args['command'] != '' { 'cmd ${args['command']}' } else { name }
		}
		'grep' {
			if args['pattern'] != '' {
				if args['path'] != '' && args['path'] != '.' {
					'grep "${args['pattern']}" ${args['path']}'
				} else {
					'grep "${args['pattern']}"'
				}
			} else {
				name
			}
		}
		'glob' {
			if args['pattern'] != '' {
				if args['path'] != '' && args['path'] != '.' {
					'glob "${args['pattern']}" ${args['path']}'
				} else {
					'glob "${args['pattern']}"'
				}
			} else {
				name
			}
		}
		'list_dir' {
			p := if args['path'] != '' { args['path'] } else { '.' }
			'list_dir ${p}'
		}
		'subagent' {
			if args['prompt'] != '' {
				clean_prompt := args['prompt'].trim_space().replace('\r', '')
				'subagent: ${clean_prompt}'
			} else {
				name
			}
		}
		'task' {
			if args['task_id'] != '' {
				'task ${args['action']} ${args['task_id']}'
			} else if args['action'] != '' {
				'task ${args['action']}'
			} else {
				name
			}
		}
		'web_search' {
			if args['query'] != '' {
				'web_search "${args['query']}"'
			} else {
				name
			}
		}
		'web_fetch' {
			if args['url'] != '' {
				'web_fetch ${args['url']}'
			} else {
				name
			}
		}
		else {
			name
		}
	}
}

fn (mut a Agent) stream_with_retry(prompt string, cb AgentCallbacks) ?llm.StreamResult {
	mut current_prompt := prompt
	mut attempt := 1
	max_retries := 3

	for {
		result := a.client.chat_stream(current_prompt, cb.on_text, unsafe { nil },
			cb.on_thinking, cb.on_tool_stream) or {
			if a.client.aborted {
				return none
			}
			if is_retryable_api_error(err.str()) && attempt < max_retries {
				delay_s := attempt * 2
				if cb.on_retry != unsafe { nil } {
					cb.on_retry(attempt, max_retries, delay_s, err.str())
				}
				for _ in 0 .. (delay_s * 10) {
					if a.client.aborted {
						return none
					}
					time.sleep(100 * time.millisecond)
				}
				attempt++
				current_prompt = ''
				continue
			}
			if cb.on_error != unsafe { nil } {
				cb.on_error(err.str())
			}
			return none
		}
		return result
	}
	return none
}

struct PreparedToolCall {
	call_id       string
	tc            llm.ToolCall
	args          map[string]string
	display_title string
}

struct ToolExecutionResult {
	id      string
	name    string
	result  tools.ToolResult
	preview string
}

fn (a &Agent) is_mcp_tool(name string) bool {
	if a.mcp_manager == unsafe { nil } {
		return false
	}
	if _ := a.mcp_manager.find_tool(name) {
		return true
	}
	return false
}

fn (a &Agent) dispatch_single_tool(call_id string, tc llm.ToolCall, args map[string]string, cb AgentCallbacks, _parent_id string) (tools.ToolResult, string) {
	mut tool_result := tools.ToolResult{}
	if tc.name == 'subagent' {
		if a.is_subagent {
			tool_result = tools.ToolResult{
				content:  'Error: nested subagents are not permitted'
				is_error: true
			}
		} else {
			tool_result = a.run_subagent(call_id, args['prompt'], args['read_only'] == 'true', cb)
		}
	} else if a.is_mcp_tool(tc.name) {
		mut mcp_args := tc.input.trim_space()
		if !(mcp_args.starts_with('{') && mcp_args.ends_with('}')) {
			mcp_args = '{}'
		}
		mut mcp_mgr := unsafe { a.mcp_manager }
		if mcp_result := mcp_mgr.call_tool(tc.name, mcp_args) {
			mut tr := tools.ToolResult{
				content:  mcp_result.text
				is_error: false
			}
			if mcp_result.images.len > 0 {
				img := mcp_result.images[0]
				if img.data.len > 0 {
					tr = tools.ToolResult{
						content:    mcp_result.text
						is_error:   false
						image_data: tools.ImageData{
							data:      img.data
							mime_type: if img.mime_type.len > 0 { img.mime_type } else { 'image/png' }
							name:      if img.name.len > 0 { img.name } else { 'screenshot' }
						}
					}
				}
			}
			tool_result = tr
		} else {
			tool_result = tools.ToolResult{
				content:  'MCP tool "${tc.name}" failed: ${err.str()}'
				is_error: true
			}
		}
	} else {
		tool_result = tools.execute_tool(tc.name, args)
	}

	display_content := if tc.name == 'write' && !tool_result.is_error && args['content'].len > 0 {
		args['content']
	} else if tc.name == 'edit' && !tool_result.is_error && tool_result.diff.len > 0 {
		tool_result.diff
	} else if tc.name == 'edit' && !tool_result.is_error && args['new_text'].len > 0 {
		args['new_text']
	} else {
		tool_result.content
	}

	return tool_result, display_content
}

fn (a &Agent) execute_tool_worker(call_id string, tc llm.ToolCall, args map[string]string, cb AgentCallbacks, parent_id string) ToolExecutionResult {
	tool_result, preview := a.dispatch_single_tool(call_id, tc, args, cb, parent_id)
	if cb.on_tool_result != unsafe { nil } {
		cb.on_tool_result(call_id, tc.name, preview, tool_result.is_error, parent_id)
	}
	return ToolExecutionResult{
		id:      call_id
		name:    tc.name
		result:  tool_result
		preview: preview
	}
}

// run executes the agent loop: send prompt, handle tool calls, repeat until done.
pub fn (mut a Agent) run(prompt string, cb AgentCallbacks) {
	a.client.aborted = false
	a.prepare_tool_schemas()

	mut current_prompt := prompt

	for turn := 0; turn < a.max_turns; turn++ {
		if compact.should_compact(&a.client) {
			compact.compact(mut a.client, '') or {}
		}

		result := a.stream_with_retry(current_prompt, cb) or { return }

		if a.client.aborted {
			a.client.add_user_message('[Request interrupted by user]')
			if cb.on_complete != unsafe { nil } {
				cb.on_complete()
			}
			return
		}

		if result.tool_calls.len == 0 {
			if cb.on_complete != unsafe { nil } {
				cb.on_complete()
			}
			return
		}

		mut tool_results := map[string]tools.ToolResult{}
		if result.tool_calls.len == 1 {
			tc := result.tool_calls[0]
			call_id := if tc.id.len > 0 { tc.id } else { 'call_${time.now().unix_micro()}_0' }
			args := parse_tool_input(tc.input)
			display_title := format_tool_display_title(tc.name, args)
			if cb.on_tool_call != unsafe { nil } {
				cb.on_tool_call(call_id, tc.name, tc.input, display_title, '')
			}

			tool_result, preview := a.dispatch_single_tool(call_id, tc, args, cb, '')
			if cb.on_tool_result != unsafe { nil } {
				cb.on_tool_result(call_id, tc.name, preview, tool_result.is_error, '')
			}
			tool_results[call_id] = tool_result
		} else {
			mut prepared_calls := []PreparedToolCall{}
			for idx, tc in result.tool_calls {
				call_id := if tc.id.len > 0 { tc.id } else { 'call_${time.now().unix_micro()}_${idx}' }
				args := parse_tool_input(tc.input)
				display_title := format_tool_display_title(tc.name, args)
				if cb.on_tool_call != unsafe { nil } {
					cb.on_tool_call(call_id, tc.name, tc.input, display_title, '')
				}
				prepared_calls << PreparedToolCall{
					call_id:       call_id
					tc:            tc
					args:          args
					display_title: display_title
				}
			}

			mut threads := []thread ToolExecutionResult{}
			for prep in prepared_calls {
				threads << spawn a.execute_tool_worker(prep.call_id, prep.tc, prep.args, cb, '')
			}

			collected_results := threads.wait()
			for r in collected_results {
				tool_results[r.id] = r.result
			}
		}

		a.client.add_tool_results(tool_results)
		current_prompt = ''
	}

	if cb.on_error != unsafe { nil } {
		cb.on_error('max turns reached (${a.max_turns})')
	}
}

fn normalize_tool_path(raw_path string) string {
	mut p := raw_path.trim_space()
	if (p.starts_with('"') && p.ends_with('"')) || (p.starts_with("'") && p.ends_with("'")) {
		if p.len >= 2 {
			p = p[1..p.len - 1].trim_space()
		}
	}
	p = p.replace('\\', '/')
	return p
}

fn canonicalize_tool_args(mut m map[string]string) map[string]string {
	if 'path' !in m {
		if 'file_path' in m {
			m['path'] = m['file_path']
		} else if 'filePath' in m {
			m['path'] = m['filePath']
		}
	}
	if 'path' in m {
		m['path'] = normalize_tool_path(m['path'])
	}
	if 'command' !in m && 'cmd' in m {
		m['command'] = m['cmd']
	}
	if 'prompt' !in m && 'input' in m {
		m['prompt'] = m['input']
	}
	if 'content' !in m && 'text' in m {
		m['content'] = m['text']
	}
	if 'task_id' !in m && 'taskId' in m {
		m['task_id'] = m['taskId']
	}
	if 'wait_ms' !in m && 'waitMs' in m {
		m['wait_ms'] = m['waitMs']
	}
	if 'old_text' !in m && 'oldText' in m {
		m['old_text'] = m['oldText']
	}
	if 'new_text' !in m && 'newText' in m {
		m['new_text'] = m['newText']
	}
	if 'read_only' !in m && 'readOnly' in m {
		m['read_only'] = m['readOnly']
	}
	if 'ignore_case' !in m && 'ignoreCase' in m {
		m['ignore_case'] = m['ignoreCase']
	}
	if 'query' !in m && 'q' in m {
		m['query'] = m['q']
	}
	if 'url' !in m && 'link' in m {
		m['url'] = m['link']
	}
	return m
}

// parse_tool_input parses the tool call arguments JSON into normalized string key-value pairs.
fn parse_tool_input(input string) map[string]string {
	flat := utils.parse_flat_json(input) or {
		repaired := utils.repair_json(input)
		utils.parse_flat_json(repaired) or {
			map[string]string{}
		}
	}
	mut flat_map := flat.clone()
	return canonicalize_tool_args(mut flat_map)
}

