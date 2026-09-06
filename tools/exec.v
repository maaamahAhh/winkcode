module tools

import os
import strings
import time

// Execution engine for external shell processes and commands.
// Background task promotion adapted from Google Antigravity architecture.

fn run_exec_process(mut p os.Process, timeout_sec int, wait_ms int, cmd_display string) ToolResult {
	p.set_redirect_stdio_merged()
	p.run()

	start := time.ticks()
	mut output_sb := strings.new_builder(4096)

	// If wait_ms is specified, wait synchronously up to wait_ms before converting to a background task
	if wait_ms > 0 {
		for p.is_alive() {
			if time.ticks() - start >= i64(wait_ms) {
				break
			}
			chunk := p.stdout_read()
			if chunk.len > 0 {
				output_sb.write_string(chunk)
			}
			time.sleep(20 * time.millisecond)
		}
		if p.is_alive() {
			initial_out := output_sb.str().trim_space()
			mut tm := get_task_manager()
			tid := tm.register(cmd_display, mut p, initial_out)
			return ToolResult{
				content:  'Command is running in the background with task ID: ${tid}\nOutput so far:\n${initial_out}'
				is_error: false
			}
		}
	}

	mut timed_out := false
	if timeout_sec > 0 {
		timeout_ms := i64(timeout_sec) * 1000
		for p.is_alive() {
			chunk := p.stdout_read()
			if chunk.len > 0 {
				output_sb.write_string(chunk)
			}
			if time.ticks() - start >= timeout_ms {
				timed_out = true
				kill_process_tree(mut p)
				break
			}
			time.sleep(30 * time.millisecond)
		}
	} else {
		for p.is_alive() {
			chunk := p.stdout_read()
			if chunk.len > 0 {
				output_sb.write_string(chunk)
			}
			time.sleep(30 * time.millisecond)
		}
	}

	// Drain any remaining output in the pipe
	for {
		chunk := p.stdout_read()
		if chunk.len == 0 {
			break
		}
		output_sb.write_string(chunk)
	}

	p.wait()

	mut output := output_sb.str().trim_space()
	if output.len > 50000 {
		output = truncate_output(output, 50000)
	}

	if timed_out {
		return ToolResult{
			content:  'Command timed out after ${timeout_sec}s\n${output}'
			is_error: true
		}
	}

	if p.code != 0 {
		return ToolResult{
			content:  'Exit code: ${p.code}\n${output}'
			is_error: true
		}
	}
	return ToolResult{
		content:  output
		is_error: false
	}
}

fn run_exec(executable string, args []string, timeout_sec int, wait_ms int, cmd_display string) ToolResult {
	exe := os.find_abs_path_of_executable(executable) or { executable }
	mut p := os.new_process(exe)
	p.set_args(args)
	return run_exec_process(mut p, timeout_sec, wait_ms, cmd_display)
}

fn tool_bash(args map[string]string) ToolResult {
	cmd := args['command'] or {
		return ToolResult{
			content:  'Error: command is required'
			is_error: true
		}
	}
	timeout_sec := if 'timeout' in args { args['timeout'].int() } else { 0 }
	wait_ms := if 'wait_ms' in args { args['wait_ms'].int() } else { 0 }
	return run_exec('bash', ['-c', cmd], timeout_sec, wait_ms, cmd)
}

fn tool_pwsh(args map[string]string) ToolResult {
	cmd := args['command'] or {
		return ToolResult{
			content:  'Error: command is required'
			is_error: true
		}
	}
	timeout_sec := if 'timeout' in args { args['timeout'].int() } else { 0 }
	wait_ms := if 'wait_ms' in args { args['wait_ms'].int() } else { 0 }
	return run_exec('powershell', ['-NoProfile', '-Command', cmd], timeout_sec, wait_ms, cmd)
}

fn run_cmd_bat(cmd string, timeout_sec int, wait_ms int) ToolResult {
	temp_bat := os.join_path(os.temp_dir(), 'wink_cmd_${time.ticks()}_${os.getpid()}.bat')
	bat_content := '@chcp 65001 >nul\r\n@echo off\r\n' + cmd
	os.write_file(temp_bat, bat_content) or {
		return ToolResult{
			content:  'Failed to create temp batch script: ${err.str()}'
			is_error: true
		}
	}
	defer {
		os.rm(temp_bat) or {}
	}

	mut cmd_exe := os.getenv('ComSpec')
	if cmd_exe.len == 0 {
		$if windows {
			cmd_exe = 'C:\\Windows\\System32\\cmd.exe'
		} $else {
			cmd_exe = os.find_abs_path_of_executable('cmd.exe') or {
				return run_exec('sh', ['-c', cmd], timeout_sec, wait_ms, cmd)
			}
		}
	}

	mut p := os.new_process(cmd_exe)
	p.set_args(['/d', '/c', temp_bat])
	return run_exec_process(mut p, timeout_sec, wait_ms, cmd)
}

fn tool_cmd(args map[string]string) ToolResult {
	cmd := args['command'] or {
		return ToolResult{
			content:  'Error: command is required'
			is_error: true
		}
	}
	timeout_sec := if 'timeout' in args { args['timeout'].int() } else { 0 }
	wait_ms := if 'wait_ms' in args { args['wait_ms'].int() } else { 0 }
	return run_cmd_bat(cmd, timeout_sec, wait_ms)
}
