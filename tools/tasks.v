module tools

import os
import sync
import time
import strings

// Background task lifecycle and output buffer management.
// Adapted from Google Antigravity architecture.

pub struct BackgroundTask {
pub mut:
	id         string
	command    string
	process    &os.Process = unsafe { nil }
	output_buf strings.Builder
	start_time time.Time
	mu         sync.Mutex
	is_done    bool
	exit_code  int
}

pub struct TaskManager {
pub mut:
	tasks map[string]&BackgroundTask
	seq   int
	mu    sync.Mutex
}

pub fn get_task_manager() &TaskManager {
	unsafe {
		mut static tm := &TaskManager(nil)
		if tm == nil {
			tm = &TaskManager{
				tasks: map[string]&BackgroundTask{}
			}
		}
		return tm
	}
}

pub fn (mut tm TaskManager) register(command string, mut p os.Process, initial_output string) string {
	tm.mu.lock()
	defer { tm.mu.unlock() }
	tm.seq++
	tid := 'task_${tm.seq}'

	mut buf := strings.new_builder(16384)
	if initial_output.len > 0 {
		buf.writeln(initial_output)
	}

	mut task := &BackgroundTask{
		id:         tid
		command:    command
		process:    p
		output_buf: buf
		start_time: time.now()
		is_done:    false
		exit_code:  0
	}

	tm.tasks[tid] = task

	// Spawn background reader thread to continuously drain stdout/stderr
	go fn [mut task] () {
		for task.process.is_alive() {
			chunk := task.process.stdout_read()
			if chunk.len > 0 {
				task.mu.lock()
				task.output_buf.write_string(chunk)
				task.mu.unlock()
			}
			time.sleep(40 * time.millisecond)
		}
		// Drain remaining output in the pipe after process exit
		for {
			rem := task.process.stdout_read()
			if rem.len == 0 {
				break
			}
			task.mu.lock()
			task.output_buf.write_string(rem)
			task.mu.unlock()
		}
		task.process.wait()
		task.mu.lock()
		task.is_done = true
		task.exit_code = task.process.code
		task.mu.unlock()
	}()

	return tid
}

fn (tm TaskManager) resolve_task_id(raw_id string) string {
	trimmed := raw_id.trim_space()
	if trimmed in tm.tasks {
		return trimmed
	}
	// Support numeric shorthand: "1" -> "task_1"
	prefixed := 'task_${trimmed}'
	if prefixed in tm.tasks {
		return prefixed
	}
	// Support un-underscored shorthand: "task1" -> "task_1"
	if trimmed.starts_with('task') && !trimmed.starts_with('task_') {
		candidate := 'task_${trimmed[4..]}'
		if candidate in tm.tasks {
			return candidate
		}
	}
	return trimmed
}

pub fn (mut tm TaskManager) get_status(tid string) (string, bool) {
	tm.mu.lock()
	defer { tm.mu.unlock() }
	resolved_id := tm.resolve_task_id(tid)
	mut task := tm.tasks[resolved_id] or { return 'Task not found: ${tid}', false }

	task.mu.lock()
	defer { task.mu.unlock() }

	status := if task.process.is_alive() {
		'running'
	} else {
		'finished (exit code: ${task.exit_code})'
	}
	out := task.output_buf.str().trim_space()
	return 'Task ${resolved_id} (${task.command})\nStatus: ${status}\nOutput:\n${out}', true
}

pub fn kill_process_tree(mut p os.Process) {
	if !p.is_alive() {
		return
	}
	$if windows {
		if p.pid > 0 {
			os.execute('taskkill /F /T /PID ${p.pid}')
		}
		p.signal_kill()
	} $else {
		p.signal_kill()
	}
}

pub fn (mut tm TaskManager) kill(tid string) (string, bool) {
	tm.mu.lock()
	defer { tm.mu.unlock() }
	resolved_id := tm.resolve_task_id(tid)
	mut task := tm.tasks[resolved_id] or { return 'Task not found: ${tid}', false }

	if task.process.is_alive() {
		kill_process_tree(mut task.process)
		task.process.wait()
		task.mu.lock()
		task.is_done = true
		task.exit_code = -1
		task.mu.unlock()
		return 'Task ${resolved_id} terminated.', true
	}
	return 'Task ${resolved_id} is already finished.', true
}

pub fn (mut tm TaskManager) list() string {
	tm.mu.lock()
	defer { tm.mu.unlock() }
	if tm.tasks.len == 0 {
		return 'No background tasks running.'
	}
	mut lines := ['ID\tSTATUS\tCOMMAND']
	for tid, task in tm.tasks {
		status := if task.process.is_alive() { 'running' } else { 'finished' }
		lines << '${tid}\t${status}\t${task.command}'
	}
	return lines.join('\n')
}

pub fn (mut tm TaskManager) kill_all() {
	tm.mu.lock()
	defer { tm.mu.unlock() }
	for _, mut task in tm.tasks {
		if task.process.is_alive() {
			kill_process_tree(mut task.process)
		}
	}
}

pub fn cleanup_tasks() {
	mut tm := get_task_manager()
	tm.kill_all()
}

pub fn tool_task(args map[string]string) ToolResult {
	action := args['action'] or { 'list' }
	task_id := args['task_id'] or { '' }
	mut tm := get_task_manager()

	match action {
		'list' {
			return ToolResult{
				content:  tm.list()
				is_error: false
			}
		}
		'status' {
			if task_id.len == 0 {
				return ToolResult{
					content:  'Error: task_id is required for action "status"'
					is_error: true
				}
			}
			out, ok := tm.get_status(task_id)
			return ToolResult{
				content:  out
				is_error: !ok
			}
		}
		'kill' {
			if task_id.len == 0 {
				return ToolResult{
					content:  'Error: task_id is required for action "kill"'
					is_error: true
				}
			}
			out, ok := tm.kill(task_id)
			return ToolResult{
				content:  out
				is_error: !ok
			}
		}
		else {
			return ToolResult{
				content:  'Unknown action: ${action}. Expected "list", "status", or "kill".'
				is_error: true
			}
		}
	}
}
