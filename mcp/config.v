module mcp

import os
import json

pub struct McpConfig {
pub:
	name    string
	command string
	args    []string
	env     map[string]string
}

pub fn load_mcp_config(cwd string) []McpConfig {
	mut configs := []McpConfig{}

	// Project-level: .winkcode/mcp.json
	project_path := os.join_path(cwd, '.winkcode', 'mcp.json')
	if os.is_file(project_path) {
		configs << parse_mcp_file(project_path)
	}

	// Global: ~/.winkcode/mcp.json
	home := os.home_dir()
	global_path := os.join_path(home, '.winkcode', 'mcp.json')
	if os.is_file(global_path) {
		configs << parse_mcp_file(global_path)
	}

	return configs
}

struct McpServerEntry {
	command string
	args    []string
	env     map[string]string
}

struct McpFile {
	mcp_servers map[string]McpServerEntry @[json: 'mcpServers']
}

fn parse_mcp_file(path string) []McpConfig {
	mut configs := []McpConfig{}
	content := os.read_file(path) or { return configs }
	file := json.decode(McpFile, content) or { return configs }
	for name in file.mcp_servers.keys() {
		entry := file.mcp_servers[name]
		if entry.command.len > 0 {
			configs << McpConfig{
				name:    name
				command: entry.command
				args:    entry.args
				env:     entry.env
			}
		}
	}
	return configs
}
