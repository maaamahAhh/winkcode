module tools

import strings

fn tool_definitions() []ToolDef {
	return [
		ToolDef{
			name:        'read'
			description: 'Read text or image file contents with optional line offset and limit'
			params_json: '{"type":"object","properties":{"path":{"type":"string","description":"File path to read"},"offset":{"type":"integer","description":"1-indexed line number to start from"},"limit":{"type":"integer","description":"Number of lines to read"}},"required":["path"]}'
		},
		ToolDef{
			name:        'write'
			description: 'Write content to a file, creating parent directories if needed'
			params_json: '{"type":"object","properties":{"path":{"type":"string","description":"File path to write"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}'
		},
		ToolDef{
			name:        'edit'
			description: 'Exact string replacement in a file. Fails if old_text is not found or not unique.'
			params_json: '{"type":"object","properties":{"path":{"type":"string","description":"File path to edit"},"old_text":{"type":"string","description":"Exact text to find and replace"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path","old_text","new_text"]}'
		},
		ToolDef{
			name:        'bash'
			description: 'Execute a bash command and return output'
			params_json: '{"type":"object","properties":{"command":{"type":"string","description":"Bash command to execute"},"timeout":{"type":"integer","description":"Optional timeout in seconds"},"wait_ms":{"type":"integer","description":"Optional milliseconds to wait synchronously before promoting to a background task"}},"required":["command"]}'
		},
		ToolDef{
			name:        'pwsh'
			description: 'Execute a PowerShell command and return output'
			params_json: '{"type":"object","properties":{"command":{"type":"string","description":"PowerShell command to execute"},"timeout":{"type":"integer","description":"Optional timeout in seconds"},"wait_ms":{"type":"integer","description":"Optional milliseconds to wait synchronously before promoting to a background task"}},"required":["command"]}'
		},
		ToolDef{
			name:        'cmd'
			description: 'Execute a cmd.exe command and return output'
			params_json: '{"type":"object","properties":{"command":{"type":"string","description":"Command to execute via cmd /C"},"timeout":{"type":"integer","description":"Optional timeout in seconds"},"wait_ms":{"type":"integer","description":"Optional milliseconds to wait synchronously before promoting to a background task"}},"required":["command"]}'
		},
		ToolDef{
			name:        'grep'
			description: 'Search file contents for a pattern'
			params_json: '{"type":"object","properties":{"pattern":{"type":"string","description":"Search pattern"},"path":{"type":"string","description":"Directory to search in (default .)"},"glob":{"type":"string","description":"File name glob pattern to filter"},"ignore_case":{"type":"boolean","description":"Case insensitive search"},"limit":{"type":"integer","description":"Max results (default 100)"}},"required":["pattern"]}'
		},
		ToolDef{
			name:        'glob'
			description: 'Find files matching a glob pattern'
			params_json: '{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (supports * and ?)"},"path":{"type":"string","description":"Directory to search in (default .)"}},"required":["pattern"]}'
		},
		ToolDef{
			name:        'list_dir'
			description: 'List directory contents, directories first with / suffix'
			params_json: '{"type":"object","properties":{"path":{"type":"string","description":"Directory path (default .)"}},"required":[]}'
		},
		ToolDef{
			name:        'task'
			description: 'Manage background tasks: list running tasks, check output status, or terminate a task'
			params_json: '{"type":"object","properties":{"action":{"type":"string","enum":["list","status","kill"],"description":"Action to perform: list, status, or kill"},"task_id":{"type":"string","description":"Task ID (required for status and kill)"}},"required":["action"]}'
		},
		ToolDef{
			name:        'web_search'
			description: 'Search the web using DuckDuckGo, Bing, or Exa API and return ranked results with snippets'
			params_json: '{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"limit":{"type":"integer","description":"Max number of results to return (default 8, max 20)"}},"required":["query"]}'
		},
		ToolDef{
			name:        'web_fetch'
			description: 'Fetch content from a URL and convert it to clean, readable Markdown'
			params_json: '{"type":"object","properties":{"url":{"type":"string","description":"HTTP or HTTPS URL to fetch"},"raw":{"type":"boolean","description":"Optional. If true, returns raw HTML without converting to Markdown"},"local":{"type":"boolean","description":"Optional. If true, bypasses remote reader and fetches directly"}},"required":["url"]}'
		},
	]
}

fn format_anthropic_schemas(defs []ToolDef) string {
	mut sb := strings.new_builder(4096)
	sb.writeln('[')
	for i, def in defs {
		if i > 0 {
			sb.writeln(',')
		}
		sb.writeln('{"name":"${def.name}","description":"${def.description}","input_schema":${def.params_json}}')
	}
	sb.writeln(']')
	return sb.str()
}

fn format_openai_schemas(defs []ToolDef) string {
	mut sb := strings.new_builder(4096)
	sb.writeln('[')
	for i, def in defs {
		if i > 0 {
			sb.writeln(',')
		}
		sb.writeln('{"type":"function","function":{"name":"${def.name}","description":"${def.description}","parameters":${def.params_json}}}')
	}
	sb.writeln(']')
	return sb.str()
}

// Anthropic format: [{"name":"...","description":"...","input_schema":{...}}]
pub fn get_schemas() string {
	return format_anthropic_schemas(tool_definitions())
}

// get_subagent_schemas returns Anthropic tool schemas for subagents, optionally filtered to read-only tools
pub fn get_subagent_schemas(read_only bool) string {
	defs := tool_definitions().filter(!read_only || it.name in ['read', 'grep', 'glob', 'list_dir', 'web_search', 'web_fetch'])
	return format_anthropic_schemas(defs)
}

// OpenAI format: [{"type":"function","function":{"name":"...","description":"...","parameters":{...}}}]
pub fn get_schemas_openai() string {
	return format_openai_schemas(tool_definitions())
}

// get_subagent_schemas_openai returns OpenAI tool schemas for subagents, optionally filtered to read-only tools
pub fn get_subagent_schemas_openai(read_only bool) string {
	defs := tool_definitions().filter(!read_only || it.name in ['read', 'grep', 'glob', 'list_dir', 'web_search', 'web_fetch'])
	return format_openai_schemas(defs)
}

pub fn merge_schemas(a string, b string) string {
	if a.len == 0 {
		return b
	}
	if b.len == 0 {
		return a
	}
	mut a_content := a.trim_space().trim('[]')
	mut b_content := b.trim_space().trim('[]')
	if a_content.len > 0 && b_content.len > 0 {
		return '[${a_content},${b_content}]'
	} else if a_content.len > 0 {
		return '[${a_content}]'
	} else {
		return '[${b_content}]'
	}
}

pub fn execute_tool(name string, args map[string]string) ToolResult {
	match name {
		'read' {
			return tool_read(args)
		}
		'write' {
			return tool_write(args)
		}
		'edit' {
			return tool_edit(args)
		}
		'bash' {
			return tool_bash(args)
		}
		'pwsh' {
			return tool_pwsh(args)
		}
		'cmd' {
			return tool_cmd(args)
		}
		'grep' {
			return tool_grep(args)
		}
		'glob' {
			return tool_glob(args)
		}
		'list_dir' {
			return tool_list_dir(args)
		}
		'task' {
			return tool_task(args)
		}
		'web_search' {
			return tool_web_search(args)
		}
		'web_fetch' {
			return tool_web_fetch(args)
		}
		else {
			return ToolResult{
				content:  'Unknown tool: ${name}'
				is_error: true
			}
		}
	}
}
