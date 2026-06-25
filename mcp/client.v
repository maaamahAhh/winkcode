module mcp

import os
import time
import json

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
		os.find_abs_path_of_executable(server.command) or {
			return
		}
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

fn mcp_send_request(mut server McpServer, method string, params string) !string {
	return mcp_send_request_with_timeout(mut server, method, params, default_mcp_request_timeout_ms)
}

fn mcp_send_request_with_timeout(mut server McpServer, method string, params string, timeout_ms int) !string {
	server.request_id++
	id := server.request_id

	mut request := '{"jsonrpc":"2.0","id":${id},"method":"${method}"'
	if params.len > 0 {
		request += ',"params":${params}'
	}
	request += '}\n'

	server.process.stdin_write(request)

	return mcp_read_response(mut server, id, timeout_ms)
}

fn mcp_send_notification(mut server McpServer, method string, params string) {
	mut request := '{"jsonrpc":"2.0","method":"${method}"'
	if params.len > 0 {
		request += ',"params":${params}'
	}
	request += '}\n'
	server.process.stdin_write(request)
}

fn mcp_read_response(mut server McpServer, expected_id int, timeout_ms int) !string {
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
	params := '{"protocolVersion":"2024-11-05","capabilities":{"roots":{"listChanged":true}},"clientInfo":{"name":"wink-code","version":"0.0.1"}}'
	response := mcp_send_request_with_timeout(mut server, 'initialize', params, 60000) or {
		return false
	}
	if response.contains('"id"') && !response.contains('"error"') {
		mcp_send_notification(mut server, 'notifications/initialized', '{}')
		return true
	}
	return false
}

fn mcp_list_tools(mut server McpServer) {
	response := mcp_send_request_with_timeout(mut server, 'tools/list', '{}', 30000) or {
		return
	}
	server.tools = parse_mcp_tools(response)
}

fn mcp_call_tool(mut server McpServer, tool_name string, arguments string) !McpToolResult {
	params := '{"name":"${tool_name}","arguments":${arguments}}'
	response := mcp_send_request_with_timeout(mut server, 'tools/call', params, default_mcp_request_timeout_ms) or {
		return error('MCP call failed: ${err}')
	}
	return parse_mcp_call_result(response)
}

// --- Response Parsing ---

fn extract_json_string_field(json_str string, field string) string {
	key := '"${field}"'
	idx := json_str.index(key) or { return '' }
	if idx < 0 {
		return ''
	}
	mut start := idx + key.len
	// skip colon and whitespace
	for start < json_str.len && (json_str[start] == `:` || json_str[start] == ` ` || json_str[start] == `\t`) {
		start++
	}
	if start >= json_str.len {
		return ''
	}
	if json_str[start] != `"` {
		return ''
	}
	start++ // skip opening quote
	mut end := start
	mut escaped := false
	for end < json_str.len {
		c := json_str[end]
		if escaped {
			escaped = false
			end++
			continue
		}
		if c == `\\` {
			escaped = true
			end++
			continue
		}
		if c == `"` {
			break
		}
		end++
	}
	if end >= json_str.len {
		return ''
	}
	return json_str[start..end]
}

fn extract_json_string_array(json_str string, field string) []string {
	key := '"${field}"'
	idx := json_str.index(key) or { return []string{} }
	if idx < 0 {
		return []string{}
	}
	mut start := idx + key.len
	for start < json_str.len && (json_str[start] == `:` || json_str[start] == ` ` || json_str[start] == `\t`) {
		start++
	}
	if start >= json_str.len || json_str[start] != `[` {
		return []string{}
	}
	start++ // skip [
	mut result := []string{}
	mut i := start
	for i < json_str.len {
		if json_str[i] == `"` {
			i++
			mut s_start := i
			mut escaped := false
			for i < json_str.len {
				if escaped {
					escaped = false
					i++
					continue
				}
				if json_str[i] == `\\` {
					escaped = true
					i++
					continue
				}
				if json_str[i] == `"` {
					break
				}
				i++
			}
			if i < json_str.len {
				result << json_str[s_start..i]
			}
		}
		for i < json_str.len && json_str[i] != `"` {
			if json_str[i] == `]` {
				return result
			}
			i++
		}
	}
	return result
}

pub fn (m McpManager) get_tool_schemas(api_format string) string {
	tools := m.get_all_tools()
	if tools.len == 0 {
		return ''
	}
	mut parts := []string{}
	for tool in tools {
		if api_format == 'openai' {
			parts << '{"type":"function","function":{"name":${json.encode(tool.name)},"description":${json.encode(tool.description)},"parameters":${tool.raw_schema}}}'
		} else {
			parts << '{"name":${json.encode(tool.name)},"description":${json.encode(tool.description)},"input_schema":${tool.raw_schema}}'
		}
	}
	return '[${parts.join(',')}]'
}

fn parse_mcp_tools(response string) []McpTool {
	mut tools := []McpTool{}
	// Find the tools array
	tools_idx := response.index('"tools"') or { return tools }
	if tools_idx < 0 {
		return tools
	}
	// Find the array start after "tools":
	arr_start := response.index_after('[{', tools_idx) or { return tools }
	// Parse individual tool objects by counting braces
	mut depth := 0
	mut in_string := false
	mut escaped := false
	mut obj_start := -1
	for i := arr_start; i < response.len; i++ {
		c := response[i]
		if escaped {
			escaped = false
			continue
		}
		if c == `\\` && in_string {
			escaped = true
			continue
		}
		if c == `"` {
			in_string = !in_string
			continue
		}
		if in_string {
			continue
		}
		if c == `{` {
			if depth == 0 {
				obj_start = i
			}
			depth++
		} else if c == `}` {
			depth--
			if depth == 0 && obj_start >= 0 {
				obj_str := response[obj_start..i + 1]
				tools << parse_single_mcp_tool(obj_str)
				obj_start = -1
			}
		} else if c == `]` && depth == 0 {
			break
		}
	}
	return tools
}

fn parse_single_mcp_tool(obj string) McpTool {
	name := extract_json_string_field(obj, 'name')
	description := extract_json_string_field(obj, 'description')

	// Extract inputSchema as raw JSON (minimax-v approach)
	mut raw_schema := '{}'
	if schema_idx := obj.index('"inputSchema":') {
		mut schema_start := schema_idx + 14
		for schema_start < obj.len && obj[schema_start] in [` `, `\t`, `\n`, `\r`] {
			schema_start++
		}
		if schema_start < obj.len && obj[schema_start] == `{` {
			mut depth := 0
			mut in_str := false
			mut escaped := false
			for q := schema_start; q < obj.len; q++ {
				c := obj[q]
				if escaped {
					escaped = false
					continue
				}
				if c == `\\` && in_str {
					escaped = true
					continue
				}
				if c == `"` {
					in_str = !in_str
					continue
				}
				if in_str {
					continue
				}
				if c == `{` {
					depth++
				} else if c == `}` {
					depth--
					if depth == 0 {
						raw_schema = obj[schema_start..q + 1]
						break
					}
				}
			}
		}
	}

	mut properties := []string{}
	mut required := []string{}
	if raw_schema != '{}' {
		properties = extract_json_string_array_from_schema(raw_schema, 0, 'properties')
		required = extract_json_string_array_from_schema(raw_schema, 0, 'required')
	}
	mut params := []McpToolParam{}
	for prop_name in properties {
		mut param := McpToolParam{
			name:        prop_name
			description: ''
			param_type:  'string'
			required:    required.contains(prop_name)
		}
		params << param
	}
	return McpTool{
		name:        name
		description: description
		params:      params
		raw_schema:  raw_schema
	}
}

fn extract_json_string_array_from_schema(obj string, start_idx int, field string) []string {
	key := '"${field}"'
	mut idx := obj.index_after(key, start_idx) or { return []string{} }
	if idx < 0 {
		return []string{}
	}
	// skip to [
	for idx < obj.len && (obj[idx] == `:` || obj[idx] == ` ` || obj[idx] == `\t`) {
		idx++
	}
	if idx >= obj.len || obj[idx] != `[` {
		return []string{}
	}
	idx++ // skip [
	mut result := []string{}
	mut i := idx
	for i < obj.len {
		if obj[i] == `"` {
			i++
			mut s_start := i
			mut escaped := false
			for i < obj.len {
				c := obj[i]
				if escaped {
					escaped = false
					i++
					continue
				}
				if c == `\\` {
					escaped = true
					i++
					continue
				}
				if c == `"` {
					break
				}
				i++
			}
			if i < obj.len {
				result << obj[s_start..i]
				i++ // skip closing quote
			}
		}
		for i < obj.len && obj[i] != `"` && obj[i] != `]` {
			i++
		}
		if i < obj.len && obj[i] == `]` {
			break
		}
	}
	return result
}

struct McpCallResultResponse {
	result struct {
		content []McpContentItem
	}
}

struct McpContentItem {
	typ        string @[json: 'type']
	text       string
	data       string @[json: 'data']
	mime_type  string @[json: 'mimeType']
}

fn parse_mcp_call_result(response string) !McpToolResult {
	data := json.decode(McpCallResultResponse, response) or {
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
					images << McpImageData{data: item.data, mime_type: mime, name: ''}
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
		text: texts.join('\n')
		images: images
	}
}
