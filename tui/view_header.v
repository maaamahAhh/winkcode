module tui

import os
import time

// Spinner frames (Braille dots animation)
const spinner_frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

// ASCII logo
const logo_lines = [
	' ██╗    ██╗ ██╗ ███╗   ██╗ ██╗  ██╗      ██████╗  ██████╗  ██████╗  ███████╗',
	' ██║    ██║ ██║ ████╗  ██║ ██║ ██╔╝     ██╔════╝ ██╔═══██╗ ██╔══██╗ ██╔════╝',
	' ██║ █╗ ██║ ██║ ██╔██╗ ██║ █████╔╝      ██║      ██║   ██║ ██║  ██║ █████╗  ',
	' ██║███╗██║ ██║ ██║╚██╗██║ ██╔═██╗      ██║      ██║   ██║ ██║  ██║ ██╔══╝  ',
	' ╚███╔███╔╝ ██║ ██║ ╚████║ ██║  ██╗     ╚██████╗ ╚██████╔╝ ██████╔╝ ███████╗',
	'  ╚══╝╚══╝  ╚═╝ ╚═╝  ╚═══╝ ╚═╝  ╚═╝      ╚═════╝  ╚═════╝  ╚═════╝  ╚══════╝',
]

fn format_tokens_k(tokens int) string {
	if tokens < 1000 {
		return '${tokens}'
	}
	k := f32(tokens) / 1000.0
	if k >= 100.0 {
		return '${int(k)}k'
	}
	return '${k:.1f}k'
}

fn get_git_branch(mut app App) string {
	now := time.ticks()
	if app.last_git_check > 0 && now - app.last_git_check < 3000 {
		return app.cached_git_branch
	}
	app.last_git_check = now

	head_path := os.join_path('.git', 'HEAD')
	if !os.exists(head_path) {
		app.cached_git_branch = ''
		return ''
	}
	content := os.read_file(head_path) or {
		app.cached_git_branch = ''
		return ''
	}.trim_space()
	if content.starts_with('ref: refs/heads/') {
		app.cached_git_branch = content[16..].trim_space()
		return app.cached_git_branch
	} else if content.len >= 7 {
		app.cached_git_branch = content[..7]
		return app.cached_git_branch
	}
	app.cached_git_branch = ''
	return ''
}

// draw_header renders the top logo and minimal product info.
fn draw_header(mut app App, width int) int {
	mut row := 1

	if app.header_mode == .full {
		for logo_line in logo_lines {
			if row > 20 {
				break
			}
			apply_color(mut app.ctx, 'accent')
			app.ctx.draw_text(1, row, truncate_by_width(logo_line, width))
			app.ctx.reset()
			row++
		}
		apply_color(mut app.ctx, 'dim')
		info := '  wink v${app.version} • ${app.ag.get_model()}'
		app.ctx.draw_text(1, row, truncate_by_width(info, width))
		app.ctx.reset()
		row++

		apply_color(mut app.ctx, 'dim')
		app.ctx.draw_text(1, row,
			'  esc to interrupt • ctrl+c to quit • ctrl+l to clear • /help for commands')
		app.ctx.reset()
		row++
	} else {
		apply_color(mut app.ctx, 'accent')
		app.ctx.draw_text(1, row, 'wink')
		app.ctx.reset()
		apply_color(mut app.ctx, 'dim')
		info := ' v${app.version} • ${app.ag.get_model()}'
		app.ctx.draw_text(1 + 4, row, truncate_by_width(info, width - 4))
		app.ctx.reset()
		row++
	}

	return row
}

// draw_loading_indicator renders spinner and elapsed execution time.
fn draw_loading_indicator(mut app App, width int, y int) {
	spinner := spinner_frames[app.spinner_frame % spinner_frames.len]

	mut elapsed_str := ''
	if app.loading_start > 0 {
		elapsed := (time.ticks() - app.loading_start) / 1000
		if elapsed < 60 {
			elapsed_str = '${elapsed}s'
		} else {
			mut m := elapsed / 60
			s := elapsed % 60
			elapsed_str = '${m}m${s}s'
		}
	}

	apply_color(mut app.ctx, 'accent')
	app.ctx.draw_text(1, y, spinner)
	app.ctx.reset()

	mut status_text := ' ' + app.status
	if elapsed_str.len > 0 {
		status_text += ' (${elapsed_str} · esc to cancel)'
	} else {
		status_text += ' (esc to cancel)'
	}
	apply_color(mut app.ctx, 'dim')
	app.ctx.draw_text(1 + visual_width(spinner), y, truncate_by_width(status_text,
		width - visual_width(spinner)))
	app.ctx.reset()
}

// draw_footer renders the high-signal status line (context tokens, git branch, cwd).
fn draw_footer(mut app App, width int, y int) {
	cur_tokens := app.ag.get_context_tokens()
	max_tokens := app.ag.get_context_window()
	pct := if max_tokens > 0 { int((f32(cur_tokens) / f32(max_tokens)) * 100.0) } else { 0 }
	ctx_str := '${format_tokens_k(cur_tokens)}/${format_tokens_k(max_tokens)} (${pct}%)'

	mut footer_parts := [ctx_str]

	git_branch := get_git_branch(mut app)
	if git_branch.len > 0 {
		footer_parts << 'git:${git_branch}'
	}

	effort := app.ag.get_effort()
	if effort.len > 0 && effort != 'default' {
		footer_parts << 'effort:${effort}'
	}

	footer_parts << get_cwd_short()

	color := if pct >= 85 {
		'red'
	} else if pct >= 70 {
		'yellow'
	} else {
		'dim'
	}

	apply_color(mut app.ctx, color)
	footer_text := footer_parts.join(' • ')
	app.ctx.draw_text(1, y, truncate_by_width(footer_text, width))
	app.ctx.reset()
}
