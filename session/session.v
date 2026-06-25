module session

import os
import time
import json
import utils

const sessions_dir_name = '.winkcode'
const sessions_subdir = 'sessions'

// SessionHeader is the first line of a .jsonl session file.
pub struct SessionHeader {
pub:
	id        string
	timestamp string
	cwd       string
	model     string
	provider  string
}

// SessionMessage represents a single message in the conversation.
pub struct SessionMessage {
pub:
	role        string
	text        string
	timestamp   string
	tool_status string // '', 'pending', 'success', 'error'
}

// Session manages reading/writing conversation sessions.
pub struct Session {
pub mut:
	header       SessionHeader
	messages     []SessionMessage
	session_path string
}

pub fn get_sessions_dir() string {
	mut home := os.home_dir()
	if home.len == 0 {
		home = os.getwd()
	}
	dir := os.join_path(home, sessions_dir_name, sessions_subdir)
	if !os.exists(dir) {
		os.mkdir_all(dir) or {}
	}
	return dir
}

pub fn generate_session_id() string {
	return time.now().unix_micro().str()
}

pub fn new_session(model string, provider string) Session {
	cwd := os.getwd()
	return Session{
		header: SessionHeader{
			id: generate_session_id()
			timestamp: time.now().custom_format('YYYY-MM-DD HH:mm:ss')
			cwd: cwd
			model: model
			provider: provider
		}
		messages: []SessionMessage{}
	}
}

pub fn (mut s Session) add_message(role string, text string) {
	s.messages << SessionMessage{
		role: role
		text: text
		timestamp: time.now().custom_format('HH:mm:ss')
		tool_status: ''
	}
}

pub fn (mut s Session) add_tool_message(name string, status string, is_error bool) {
	tool_status := if is_error { 'error' } else if status == 'done' { 'success' } else { 'pending' }
	s.messages << SessionMessage{
		role: 'tool_call'
		text: name
		timestamp: time.now().custom_format('HH:mm:ss')
		tool_status: tool_status
	}
}

pub fn session_file_path(header SessionHeader) string {
	dir := get_sessions_dir()
	ts := header.timestamp.replace(' ', '_').replace(':', '-')
	return os.join_path(dir, '${ts}_${header.id}.jsonl')
}

pub fn find_most_recent_session() ?SessionHeader {
	dir := get_sessions_dir()
	mut opts := os.WalkParams{}
	files := os.walk_ext(dir, '.jsonl', opts)
	if files.len == 0 {
		return none
	}
	// Sort ascending by filename (timestamp format = chronological order)
	mut sorted := files.clone()
	sorted.sort()
	// Last element is the most recent
	last := sorted[sorted.len - 1]
	return parse_session_header(last)
}

pub fn find_session_by_id(id string) ?SessionHeader {
	dir := get_sessions_dir()
	mut opts := os.WalkParams{}
	for file in os.walk_ext(dir, '.jsonl', opts) {
		if file.contains(id) {
			return parse_session_header(file)
		}
	}
	return none
}

pub fn list_sessions() []SessionHeader {
	dir := get_sessions_dir()
	mut headers := []SessionHeader{}
	mut opts := os.WalkParams{}
	for file in os.walk_ext(dir, '.jsonl', opts) {
		if h := parse_session_header(file) {
			headers << h
		}
	}
	return headers
}

pub fn load_session(path string) !Session {
	if !os.exists(path) {
		return error('session file not found: ${path}')
	}
	content := os.read_file(path) or {
		return error('failed to read session file: ${err}')
	}
	lines := content.split('\n')
	if lines.len == 0 {
		return error('empty session file')
	}

	// First line is the header
	header_fields := parse_json_line(lines[0])
	if header_fields['id'] == '' {
		return error('invalid session header')
	}

	mut session_header := SessionHeader{
		id: header_fields['id']
		timestamp: header_fields['timestamp']
		cwd: header_fields['cwd']
		model: header_fields['model']
		provider: header_fields['provider']
	}

	mut messages := []SessionMessage{}
	// Skip header line (index 0), start from index 1
	for i := 1; i < lines.len; i++ {
		line := lines[i].trim_space()
		if line.len == 0 {
			continue
		}
		entry := parse_json_line(line)
		if entry['type'] == 'message' {
			messages << SessionMessage{
				role: entry['role']
				text: entry['text']
				timestamp: entry['timestamp']
				tool_status: entry['tool_status']
			}
		}
	}

	return Session{
		header: session_header
		messages: messages
		session_path: path
	}
}

pub fn (s Session) save() ! {
	// Use existing session_path if available, otherwise generate from header
	path := if s.session_path.len > 0 {
		s.session_path
	} else {
		session_file_path(s.header)
	}
	mut file := os.create(path) or {
		return error('failed to create session file: ${err}')
	}

	// Write header
	mut header_map := map[string]string{}
	header_map['type'] = 'session'
	header_map['id'] = s.header.id
	header_map['timestamp'] = s.header.timestamp
	header_map['cwd'] = s.header.cwd
	header_map['model'] = s.header.model
	header_map['provider'] = s.header.provider
	file.write_string(json.encode(header_map) + '\n') or {}

	// Write messages
	for msg in s.messages {
		mut entry := map[string]string{}
		entry['type'] = 'message'
		entry['role'] = msg.role
		entry['text'] = msg.text
		entry['timestamp'] = msg.timestamp
		entry['tool_status'] = msg.tool_status
		file.write_string(json.encode(entry) + '\n') or {}
	}

	file.close()
}

pub fn (mut s Session) append_message(role string, text string) ! {
	if s.session_path.len == 0 {
		// First message — create session file
		s.header = SessionHeader{
			id: generate_session_id()
			timestamp: time.now().custom_format('YYYY-MM-DD HH:mm:ss')
			cwd: os.getwd()
			model: s.header.model
			provider: s.header.provider
		}
		s.session_path = session_file_path(s.header)
	}

	// Append to file
	mut file := os.open_append(s.session_path) or {
		return error('failed to open session file: ${err}')
	}

	mut entry := map[string]string{}
	entry['type'] = 'message'
	entry['role'] = role
	entry['text'] = text
	entry['timestamp'] = time.now().custom_format('HH:mm:ss')
	entry['tool_status'] = ''
	file.write_string(json.encode(entry) + '\n') or {}

	file.close()

	s.messages << SessionMessage{
		role: role
		text: text
		timestamp: entry['timestamp']
		tool_status: ''
	}
}

fn parse_json_line(line string) map[string]string {
	mut s := line.trim_space()
	if !s.starts_with('{') || !s.ends_with('}') {
		return map[string]string{}
	}
	s = s[1..s.len - 1].trim_space()
	return utils.parse_flat_json(s) or { map[string]string{} }
}

fn parse_session_header(path string) ?SessionHeader {
	content := os.read_file(path) or { return none }
	lines := content.split('\n')
	if lines.len == 0 {
		return none
	}
	fields := parse_json_line(lines[0])
	if fields['id'] == '' {
		return none
	}
	return SessionHeader{
		id: fields['id']
		timestamp: fields['timestamp']
		cwd: fields['cwd']
		model: fields['model']
		provider: fields['provider']
	}
}
