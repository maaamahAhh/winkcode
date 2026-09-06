module mcp

import os
import time
import json2

const default_mcp_request_timeout_ms = 30000

pub fn new_mcp_manager() McpManager {
	return McpManager{
		servers: []&McpServer{}
	}
}

pub fn (mut m McpManager) add_server(name string, command string, args []string, env map[string]string) {
	mut server := &McpServer{
		name:         name
		command:      command
		args:         args
		env:          env
		request_id:   0
		tools:        []McpTool{}
		preset_tools: []McpTool{}
		lazy_start:   false
		is_connected: false
	}
	m.servers << server
}

pub fn (mut m McpManager) add_lazy_server(name string, command string, args []string, env map[string]string, preset_tools []McpTool) {
	mut server := &McpServer{
		name:         name
		command:      command
		args:         args
		env:          env
		request_id:   0
		tools:        []McpTool{}
		preset_tools: preset_tools
		lazy_start:   true
		is_connected: false
	}
	m.servers << server
}

pub fn (mut m McpManager) start_all() {
	for mut server in m.servers {
		if server.is_connected || server.disabled {
			continue
		}
		start_mcp_server(mut server)
	}
}

pub fn (mut m McpManager) start_eager_servers() {
	for mut server in m.servers {
		if server.is_connected || server.lazy_start || server.disabled {
			continue
		}
		start_mcp_server(mut server)
	}
}

pub fn (mut m McpManager) stop_all() {
	for mut server in m.servers {
		stop_mcp_server(mut server)
	}
}

pub fn (mut m McpManager) stop_server(name string) {
	for mut server in m.servers {
		if server.name == name {
			stop_mcp_server(mut server)
			break
		}
	}
}

pub fn (m McpManager) get_all_tools() []McpTool {
	mut all := []McpTool{}
	for server in m.servers {
		if server.disabled {
			continue
		}
		if server.is_connected {
			all << server.tools
		} else if server.preset_tools.len > 0 {
			all << server.preset_tools
		}
	}
	return all
}

pub fn (m McpManager) find_tool(tool_name string) ?McpTool {
	for server in m.servers {
		if server.disabled {
			continue
		}
		for tool in server.tools {
			if tool.name == tool_name {
				return tool
			}
		}
		for tool in server.preset_tools {
			if tool.name == tool_name {
				return tool
			}
		}
	}
	return none
}

fn server_has_tool(server McpServer, tool_name string, include_preset bool) bool {
	if server.disabled {
		return false
	}
	for tool in server.tools {
		if tool.name == tool_name {
			return true
		}
	}
	if include_preset {
		for tool in server.preset_tools {
			if tool.name == tool_name {
				return true
			}
		}
	}
	return false
}

fn start_lazy_mcp_server_for_tool(mut server McpServer, tool_name string) bool {
	start_mcp_server(mut server)
	if server.is_connected && server_has_tool(server, tool_name, false) {
		return true
	}
	return false
}

pub fn (mut m McpManager) find_connected_server_for_tool(tool_name string) ?&McpServer {
	for server in m.servers {
		if !server.is_connected {
			continue
		}
		if server_has_tool(server, tool_name, false) {
			return server
		}
	}
	return none
}

pub fn (mut m McpManager) try_start_lazy_server_for_tool(tool_name string) bool {
	mut started := false
	for mut server in m.servers {
		if !server.lazy_start || !server_has_tool(server, tool_name, true) {
			continue
		}
		started = start_lazy_mcp_server_for_tool(mut server, tool_name)
		if started {
			return true
		}
	}
	return false
}

pub fn (mut m McpManager) call_tool(tool_name string, arguments string) !McpToolResult {
	m.mu.lock()
	defer { m.mu.unlock() }
	if mut server := m.find_connected_server_for_tool(tool_name) {
		return mcp_call_tool(mut server, tool_name, arguments)
	}
	if m.try_start_lazy_server_for_tool(tool_name) {
		if mut server := m.find_connected_server_for_tool(tool_name) {
			return mcp_call_tool(mut server, tool_name, arguments)
		}
	}
	for server in m.servers {
		if server.lazy_start && server_has_tool(server, tool_name, true) {
			return error('MCP tool "${tool_name}" was registered by ${server.name}, but it could not be started')
		}
	}
	return error('MCP tool "${tool_name}" not found')
}

// --- Process Management ---

fn start_mcp_server(mut server McpServer) {
	cmd := if (server.command.contains(':\\') || server.command.contains(':/'))
		&& os.is_executable(server.command) {
		server.command
	} else {
		os.find_abs_path_of_executable(server.command) or { return }
	}

	mut proc := build_mcp_process(server, cmd)
	proc.run()

	if !proc.is_alive() {
		return
	}

	server.process = proc

	time.sleep(2000 * time.millisecond)
	if !proc.is_alive() {
		return
	}

	mut initialized := false
	for attempt in 0 .. 5 {
		if attempt > 0 {
			delay_secs := attempt
			time.sleep(delay_secs * time.second)
		}
		initialized = mcp_initialize(mut server)
		if initialized {
			break
		}
	}

	if initialized {
		mcp_list_tools(mut server)
		server.is_connected = true
	} else {
		stop_mcp_server(mut server)
	}
}

fn build_mcp_process(server McpServer, command_path string) &os.Process {
	mut proc := os.new_process(command_path)
	proc.use_pgroup = true
	proc.set_args(server.args)
	proc.set_redirect_stdio()

	if server.env.len > 0 {
		mut full_env := os.environ()
		for key, val in server.env {
			full_env[key] = val
		}
		proc.set_environment(full_env)
	}
	return proc
}

fn stop_mcp_server(mut server McpServer) {
	if server.process == unsafe { nil } {
		server.is_connected = false
		return
	}
	if server.is_connected || server.process.is_alive() {
		server.process.signal_pgkill()
		server.process.wait()
	}
	server.process.close()
	server.process = unsafe { nil }
	server.tools = []McpTool{}
	server.is_connected = false
}

// --- JSON-RPC Communication ---

fn send_request(mut server McpServer, method string, params string) !string {
	return send_request_with_timeout(mut server, method, params, default_mcp_request_timeout_ms)
}

fn send_request_with_timeout(mut server McpServer, method string, params string, timeout_ms int) !string {
	server.request_id++
	id := server.request_id

	mut request := '{"jsonrpc":"2.0","id":${id},"method":"${method}"'
	if params.len > 0 {
		request += ',"params":${params}'
	}
	request += '}\n'

	server.process.stdin_write(request)

	return read_response(mut server, id, timeout_ms)
}

fn send_notification(mut server McpServer, method string, params string) {
	mut request := '{"jsonrpc":"2.0","method":"${method}"'
	if params.len > 0 {
		request += ',"params":${params}'
	}
	request += '}\n'
	server.process.stdin_write(request)
}

fn read_response(mut server McpServer, expected_id int, timeout_ms int) !string {
	mut line_buffer := ''
	mut attempts := 0
	max_attempts := (timeout_ms + 199) / 200

	for attempts < max_attempts {
		if server.process.is_pending(.stdout) {
			if chunk := server.process.pipe_read(.stdout) {
				line_buffer += chunk

				for {
					nl := line_buffer.index('\n') or { break }
					line := line_buffer[..nl].trim_space()
					line_buffer = if nl + 1 < line_buffer.len { line_buffer[nl + 1..] } else { '' }

					if line.len == 0 {
						continue
					}

					if line.contains('"method":"roots/list"') {
						if id_pos := line.index('"id":') {
							mut p := id_pos + 5
							for p < line.len && line[p] in [` `, `\t`] {
								p++
							}
							mut e := p
							for e < line.len && line[e] >= `0` && line[e] <= `9` {
								e++
							}
							if e > p {
								req_id := line[p..e]
								server.process.stdin_write('{"jsonrpc":"2.0","id":${req_id},"result":{"roots":[]}}\n')
							}
						}
						continue
					}

					id_match := line.contains('"id":${expected_id},')
						|| line.contains('"id":${expected_id}}')
						|| line.contains('"id": ${expected_id},')
						|| line.contains('"id": ${expected_id}}')
					is_response := line.contains('"result"') || line.contains('"error"')
					if id_match && line.contains('"jsonrpc"') && is_response {
						return line
					}
				}
				continue
			}
		}

		time.sleep(500 * time.millisecond)
		attempts++
	}
	return error('MCP response timeout for request ${expected_id}')
}

// --- MCP Protocol ---

fn mcp_initialize(mut server McpServer) bool {
	params := '{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"wink-code","version":"0.0.1.5"}}'
	response := send_request_with_timeout(mut server, 'initialize', params, 60000) or {
		return false
	}
	if response.contains('"id"') && !response.contains('"error"') {
		send_notification(mut server, 'notifications/initialized', '{}')
		return true
	}
	return false
}

fn mcp_list_tools(mut server McpServer) {
	response := send_request_with_timeout(mut server, 'tools/list', '{}', 30000) or { return }
	server.tools = parse_mcp_tools(response)
}

fn mcp_call_tool(mut server McpServer, tool_name string, arguments string) !McpToolResult {
	params := '{"name":"${tool_name}","arguments":${arguments}}'
	response := send_request_with_timeout(mut server, 'tools/call', params,
		default_mcp_request_timeout_ms) or { return error('MCP call failed: ${err}') }
	return parse_mcp_call_result(response)
}



pub fn (m McpManager) get_tool_schemas(api_format string) string {
	tools := m.get_all_tools()
	if tools.len == 0 {
		return ''
	}
	mut parts := []string{}
	for tool in tools {
		if api_format == 'openai' {
			parts << '{"type":"function","function":{"name":${json2.encode(tool.name)},"description":${json2.encode(tool.description)},"parameters":${tool.raw_schema}}}'
		} else {
			parts << '{"name":${json2.encode(tool.name)},"description":${json2.encode(tool.description)},"input_schema":${tool.raw_schema}}'
		}
	}
	return '[${parts.join(',')}]'
}

struct McpToolsListResponse {
pub:
	result McpToolsListResult
}

struct McpToolsListResult {
pub:
	tools []McpToolItem
}

struct McpToolItem {
pub:
	name         string
	description  string
	input_schema json2.Any @[json: 'inputSchema']
}

fn parse_mcp_tools(response string) []McpTool {
	data := json2.decode[McpToolsListResponse](response) or {
		return []McpTool{}
	}
	mut tools := []McpTool{}
	for item in data.result.tools {
		schema_str := item.input_schema.str()
		raw_schema := if schema_str.len > 0 && schema_str != '""' && schema_str != 'null' {
			schema_str
		} else {
			'{}'
		}

		mut properties := []string{}
		mut required := []string{}

		if raw_schema != '{}' {
			schema_map := item.input_schema.as_map()
			if props_any := schema_map['properties'] {
				for prop_name, _ in props_any.as_map() {
					properties << prop_name
				}
			}
			if req_any := schema_map['required'] {
				for req_item in req_any.as_array() {
					required << req_item.str()
				}
			}
		}

		mut params := []McpToolParam{}
		for prop_name in properties {
			params << McpToolParam{
				name:        prop_name
				description: ''
				param_type:  'string'
				required:    required.contains(prop_name)
			}
		}

		tools << McpTool{
			name:        item.name
			description: item.description
			params:      params
			raw_schema:  raw_schema
		}
	}
	return tools
}

struct McpCallResultResponse {
	result struct {
		content []McpContentItem
	}
}

struct McpContentItem {
	typ       string @[json: 'type']
	text      string
	data      string @[json: 'data']
	mime_type string @[json: 'mimeType']
}

fn parse_mcp_call_result(response string) !McpToolResult {
	data := json2.decode[McpCallResultResponse](response) or {
		return error('Failed to parse MCP response: ${err}')
	}
	mut texts := []string{}
	mut images := []McpImageData{}
	for item in data.result.content {
		match item.typ {
			'text' {
				if item.text.len > 0 {
					texts << item.text
				}
			}
			'image' {
				if item.data.len > 0 {
					mime := if item.mime_type.len > 0 { item.mime_type } else { 'image/png' }
					images << McpImageData{
						data:      item.data
						mime_type: mime
						name:      ''
					}
				}
			}
			'resource' {
				// resource may contain blob with base64 data
				// We handle this at a lower level if needed
			}
			else {}
		}
	}
	return McpToolResult{
		text:   texts.join('\n')
		images: images
	}
}
