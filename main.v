module main

import os
import config
import tui
import agent
import session

const version = '0.0.1.5'

struct CliArgs {
mut:
	continue_ bool
	resume_id string
}

fn parse_cli_args(args []string) CliArgs {
	mut result := CliArgs{}
	mut i := 1
	for i < args.len {
		match args[i] {
			'-c', '--continue' {
				result.continue_ = true
				i++
			}
			'-r', '--resume' {
				if i + 1 < args.len {
					result.resume_id = args[i + 1]
					i += 2
				} else {
					eprintln('Error: --resume requires a session ID')
					exit(1)
				}
			}
			else {
				i++
			}
		}
	}
	return result
}

fn main() {
	args := os.args
	cli := parse_cli_args(args)

	mut cfg := config.load()

	resolved := cfg.resolve() or {
		eprintln('Error: ${err}')
		eprintln('Set ANTHROPIC_API_KEY or OPENAI_API_KEY environment variable')
		eprintln('Or configure ~/.winkcode/auth.json')
		exit(1)
	}

	if resolved.api_key.len == 0 {
		eprintln('Error: API key not configured')
		eprintln('Set ANTHROPIC_API_KEY or OPENAI_API_KEY environment variable')
		eprintln('Or configure ~/.winkcode/auth.json')
		exit(1)
	}

	mut ag := agent.new_agent(cfg) or {
		eprintln('Error: ${err}')
		exit(1)
	}

	// Handle session flags
	if cli.resume_id.len > 0 {
		// Resume specific session
		if header := session.find_session_by_id(cli.resume_id) {
			ag.config.current_session_id = header.id
			ag.config.current_session_path = session.session_file_path(header)
		} else {
			eprintln('Error: session not found: ${cli.resume_id}')
			exit(1)
		}
	} else if cli.continue_ {
		// Continue most recent session
		if header := session.find_most_recent_session() {
			ag.config.current_session_id = header.id
			ag.config.current_session_path = session.session_file_path(header)
		}
	}

	tui.start(mut ag, version)
}
