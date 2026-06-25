module mcp

import os

pub struct McpToolParam {
pub:
	name        string
	description string
	param_type  string
	required    bool
}

pub struct McpTool {
pub:
	name        string
	description string
	params      []McpToolParam
	raw_schema  string
}

@[heap]
pub struct McpServer {
pub mut:
	name         string
	command      string
	args         []string
	env          map[string]string
	process      &os.Process = unsafe { nil }
	request_id   int
	tools        []McpTool
	preset_tools []McpTool
	lazy_start   bool
	is_connected bool
	disabled     bool
}

pub struct McpManager {
pub mut:
	servers []&McpServer
}

pub struct McpToolResult {
pub:
	text      string
	images    []McpImageData
}

pub struct McpImageData {
pub:
	data      string
	mime_type string
	name      string
}
