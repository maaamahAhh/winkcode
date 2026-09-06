module tui

import strings
import time
import utils

// prefix_line prepends a prefix string to a RenderLine and its segments.
fn prefix_line(line RenderLine, prefix string) RenderLine {
	mut l := line
	l.text = prefix + l.text
	if l.segs.len > 0 {
		mut segs := l.segs.clone()
		segs[0].text = prefix + segs[0].text
		l.segs = segs
	}
	return l
}

fn extract_streaming_field_and_content(args_json string, field_key string, content_key string) (string, string) {
	mut field_val := ''
	if field_key.len > 0 {
		key_str := '"' + field_key + '"'
		if p_idx := args_json.index(key_str) {
			mut rest := args_json[p_idx + key_str.len..]
			if colon_idx := rest.index(':') {
				rest = rest[colon_idx + 1..].trim_space()
				if rest.starts_with('"') {
					rest = rest[1..]
					if q_idx := rest.index('"') {
						field_val = rest[..q_idx].replace('\\\\', '/').replace('\\', '/')
					}
				}
			}
		}
	}

	mut content_val := ''
	if content_key.len > 0 {
		key_str := '"' + content_key + '"'
		if c_idx := args_json.index(key_str) {
			mut rest := args_json[c_idx + key_str.len..]
			if colon_idx := rest.index(':') {
				rest = rest[colon_idx + 1..].trim_space()
				if rest.starts_with('"') {
					rest = rest[1..]
					mut sb := strings.new_builder(rest.len)
					mut i := 0
					for i < rest.len {
						ch := rest[i]
						if ch == `\\` && i + 1 < rest.len {
							next := rest[i + 1]
							match next {
								`n` {
									sb.write_u8(`\n`)
								}
								`r` {
									sb.write_u8(`\r`)
								}
								`t` {
									sb.write_u8(`\t`)
								}
								`"` {
									sb.write_u8(`"`)
								}
								`\\` {
									sb.write_u8(`\\`)
								}
								`/` {
									sb.write_u8(`/`)
								}
								else {
									sb.write_u8(next)
								}
							}
							i += 2
							continue
						}
						if ch == `"` {
							break
						}
						sb.write_u8(ch)
						i++
					}
					content_val = sb.str()
				}
			}
		}
	}

	return field_val, content_val
}

const subagent_baton_frames = ['|', '/', '-', '\\']

fn subagent_baton_char() string {
	frame_idx := int((time.ticks() / 150) % 4)
	return subagent_baton_frames[frame_idx]
}

fn is_subagent_main_call(item ChatMessage) bool {
	if item.parent_id.len > 0 {
		return false
	}
	return item.role == 'tool_call'
		&& (item.text.starts_with('subagent:') || item.text == 'subagent' || item.text.starts_with('subagent ('))
		&& !item.text.starts_with('subagent >')
}

fn render_tool_result_lines(text string, role string, expand_tool_results bool, width int, is_diff bool) []RenderLine {
	mut lines := []RenderLine{}
	text_color := message_text_color(role)

	diff_mode := is_diff || (role != 'tool_error' && utils.is_diff_content(text))
	max_collapsed := if diff_mode { 12 } else { 6 }

	mut all_lines := []RenderLine{}
	for raw_line in text.split('\n') {
		line_color := if diff_mode {
			if raw_line.starts_with('+') {
				'green'
			} else if raw_line.starts_with('-') {
				'red'
			} else if raw_line.starts_with('@@') {
				'cyan'
			} else if raw_line.starts_with(' ') {
				'dim'
			} else {
				text_color
			}
		} else {
			text_color
		}

		wrapped_slices := wrap_text(raw_line, width - 4, 1000)
		if wrapped_slices.len == 0 {
			all_lines << RenderLine{
				text:  ''
				color: line_color
			}
		} else {
			for sub in wrapped_slices {
				all_lines << RenderLine{
					text:  sub
					color: line_color
				}
			}
		}
	}

	if all_lines.len > max_collapsed && !expand_tool_results {
		for k in 0 .. max_collapsed {
			lines << RenderLine{
				text:  '  │ ${all_lines[k].text}'
				color: all_lines[k].color
			}
		}
		lines << RenderLine{
			text:  '  │ ... (ctrl+o to expand)'
			color: 'dim'
		}
	} else {
		for cl in all_lines {
			lines << RenderLine{
				text:  '  │ ${cl.text}'
				color: cl.color
			}
		}
		if all_lines.len > max_collapsed && expand_tool_results {
			lines << RenderLine{
				text:  '  │ (ctrl+o to collapse)'
				color: 'dim'
			}
		}
	}
	return lines
}

pub fn build_chat_lines(messages []ChatMessage, streaming_text string, streaming_thinking string, streaming_tool_name string, streaming_tool_args string, expand_tool_results bool, is_loading bool, status string, width int, max_lines int, spinner_frame int) []RenderLine {
	mut lines := []RenderLine{}
	mut rendered_result_indices := map[int]bool{}

	mut msg_idx := 0
	for msg_idx < messages.len {
		if msg_idx in rendered_result_indices {
			msg_idx++
			continue
		}
		item := messages[msg_idx]

		// Child steps belonging to a subagent are rendered inside their parent subagent card
		if item.parent_id.len > 0 {
			msg_idx++
			continue
		}

		// Handle subagent main call and all its child steps as a group
		if is_subagent_main_call(item) {
			prefix := if item.tool_status == 'pending' {
				subagent_baton_char()
			} else {
				message_prefix(item.role, item.tool_status)
			}
			prefix_color := message_prefix_color(item.role, item.tool_status)

			mut prompt_text := ''
			mut duration_text := ''

			if item.text.starts_with('subagent:') {
				raw_content := item.text[9..].trim_space()
				prompt_text = raw_content
				if item.tool_status != 'pending' && raw_content.ends_with(')') {
					if l_paren := raw_content.last_index(' (') {
						possible_dur := raw_content[l_paren..]
						if possible_dur.ends_with('ms)') || possible_dur.ends_with('s)') {
							duration_text = possible_dur
							prompt_text = raw_content[..l_paren].trim_space()
						}
					}
				}
			}

			// Render the subagent header line
			if expand_tool_results {
				full_header := if prompt_text.len > 0 {
					'${prefix} subagent: ${prompt_text}${duration_text}'
				} else {
					'${prefix} ${item.text}'
				}
				wrapped_header := wrap_text(full_header, width - 2, 1000)
				if wrapped_header.len > 0 {
					lines << RenderLine{
						text:  wrapped_header[0]
						color: prefix_color
					}
					for k in 1 .. wrapped_header.len {
						lines << RenderLine{
							text:  '  ${wrapped_header[k]}'
							color: prefix_color
						}
					}
				} else {
					lines << RenderLine{
						text:  full_header
						color: prefix_color
					}
				}
			} else {
				if prompt_text.len > 0 {
					first_line := prompt_text.split('\n')[0].trim_space()
					prompt_runes := first_line.runes()
					display_p := if prompt_runes.len > 40 {
						prompt_runes[..40].string() + '...'
					} else if prompt_text.contains('\n') {
						first_line + '...'
					} else {
						first_line
					}
					lines << RenderLine{
						text:  '${prefix} subagent: ${display_p}${duration_text}'
						color: prefix_color
					}
				} else {
					lines << RenderLine{
						text:  '${prefix} ${item.text}'
						color: prefix_color
					}
				}
			}

			// Collect all child tool calls belonging to this subagent
			mut child_items := []ChatMessage{}
			if item.tool_id.len > 0 {
				for m in messages {
					if m.parent_id == item.tool_id {
						child_items << m
					}
				}
				msg_idx++
			} else {
				// Fallback for legacy sessions without tool_id
				mut j := msg_idx + 1
				for j < messages.len {
					next_msg := messages[j]
					if next_msg.role == 'tool_call' && next_msg.text.starts_with('subagent >') {
						child_items << next_msg
						j++
					} else {
						break
					}
				}
				msg_idx = j
			}

			// Render subagent child steps based on collapse/expand mode
			if expand_tool_results {
				for child in child_items {
					if child.role == 'tool_call' {
						child_prefix := message_prefix(child.role, child.tool_status)
						child_color := message_prefix_color(child.role, child.tool_status)
						lines << RenderLine{
							text:  '  ${child_prefix} ${child.text}'
							color: child_color
						}
					}
				}
			} else if child_items.len > 0 {
				mut completed_count := 0
				mut pending_child := ChatMessage{}
				mut has_pending_child := false

				for child in child_items {
					if child.role != 'tool_call' {
						continue
					}
					if child.tool_status == 'pending' {
						pending_child = child
						has_pending_child = true
					} else {
						completed_count++
					}
				}

				if completed_count > 0 {
					step_word := if completed_count == 1 { '1 subagent step' } else { '${completed_count} subagent steps' }
					lines << RenderLine{
						text:  '  │ ... (${step_word} · ctrl+o to expand)'
						color: 'dim'
					}
				}
				if has_pending_child {
					lines << RenderLine{
						text:  '  ⊷ ${pending_child.text}'
						color: 'tool_running'
					}
				}
			}
			// Render subagent's own result/reply right under this subagent card
			if item.tool_id.len > 0 {
				for r_idx, m in messages {
					if r_idx !in rendered_result_indices && (m.role == 'tool_result' || m.role == 'tool_error') && m.parent_id == '' && m.tool_id == item.tool_id {
						rendered_result_indices[r_idx] = true
						for rl in render_tool_result_lines(m.text, m.role, expand_tool_results, width, false) {
							lines << rl
						}
						break
					}
				}
			}
			continue
		}

		// Tool call (regular, non-subagent)
		if item.role == 'tool_call' {
			prefix := message_prefix(item.role, item.tool_status)
			prefix_color := message_prefix_color(item.role, item.tool_status)
			lines << RenderLine{
				text:  '${prefix} ${item.text}'
				color: prefix_color
			}
			if item.tool_id.len > 0 {
				for r_idx, m in messages {
					if r_idx !in rendered_result_indices && (m.role == 'tool_result' || m.role == 'tool_error') && m.parent_id == '' && m.tool_id == item.tool_id {
						rendered_result_indices[r_idx] = true
						is_edit := item.text.starts_with('edit ') || item.text == 'edit'
						for rl in render_tool_result_lines(m.text, m.role, expand_tool_results, width, is_edit) {
							lines << rl
						}
						break
					}
				}
			}
			msg_idx++
			continue
		}

		// Tool result/error: fallback for legacy sessions without tool_id or un-paired results
		if item.role == 'tool_result' || item.role == 'tool_error' {
			for rl in render_tool_result_lines(item.text, item.role, expand_tool_results, width, false) {
				lines << rl
			}
			msg_idx++
			continue
		}

		// Compaction divider & summary
		if item.role == 'compaction' {
			lines << RenderLine{
				text:  '─── ◈ Context Compacted (${item.time}) ───'
				color: 'cyan'
			}
			for cw in wrap_text(item.text, width - 4, max_lines) {
				lines << RenderLine{
					text:  '  ${cw}'
					color: 'dim'
				}
			}
			lines << RenderLine{
				text:  ''
				color: 'white'
			}
			msg_idx++
			continue
		}

		// User / assistant / system / error messages
		prefix := message_prefix(item.role, item.tool_status)
		prefix_color := message_prefix_color(item.role, item.tool_status)
		lines << RenderLine{
			text:  '${prefix} ${item.time}'
			color: prefix_color
		}

		// Render thinking block for assistant messages (before text)
		if item.role == 'assistant' && item.thinking.len > 0 {
			for tl in render_thinking(item.thinking, width - 2) {
				lines << tl
			}
		}
		// Use markdown rendering for assistant messages, plain for others
		if item.role == 'assistant' {
			md_lines := render_markdown(item.text, width - 2)
			for ml in md_lines {
				lines << prefix_line(ml, '  ')
			}
		} else {
			text_color := message_text_color(item.role)
			for wrapped in wrap_text(item.text, width - 2, max_lines) {
				lines << RenderLine{
					text:  '  ${wrapped}'
					color: text_color
				}
			}
		}
		lines << RenderLine{
			text:  ''
			color: 'white'
		}
		msg_idx++
	}
	if streaming_thinking.len > 0 || streaming_text.len > 0 || streaming_tool_name.len > 0 {
		lines << RenderLine{
			text:  '✦ ${now_formatted()}'
			color: 'cyan'
		}
		if streaming_thinking.len > 0 {
			for tl in render_thinking(streaming_thinking, width - 2) {
				lines << tl
			}
		}
		if streaming_text.len > 0 {
			md_lines := render_markdown(streaming_text, width - 2)
			for ml in md_lines {
				lines << prefix_line(ml, '  ')
			}
		}
		// The tool call is the latest output (model streams thinking/text first,
		// then the tool invocation), so it goes last in the streaming area.
		if streaming_tool_name.len > 0 {
			streaming_icon := if streaming_tool_name == 'subagent' {
				subagent_baton_char()
			} else {
				'⊷'
			}
			lines << RenderLine{
				text:  '  ${streaming_icon} ${streaming_tool_name}'
				color: 'tool_running'
			}
			if streaming_tool_args.len > 0 {
				display_body := match streaming_tool_name {
					'write' {
						_, content := extract_streaming_field_and_content(streaming_tool_args,
							'path', 'content')
						content
					}
					'edit' {
						_, content := extract_streaming_field_and_content(streaming_tool_args,
							'path', 'new_text')
						content
					}
					'subagent' {
						_, prompt := extract_streaming_field_and_content(streaming_tool_args,
							'', 'prompt')
						if prompt.len > 0 { prompt } else { streaming_tool_args }
					}
					else {
						streaming_tool_args
					}
				}
				if display_body.len > 0 {
					wrapped := wrap_text(display_body, width - 4, 10000)
					if wrapped.len <= 4 || expand_tool_results {
						for w in wrapped {
							lines << RenderLine{
								text:  '  │ ${w}'
								color: 'tool_running'
							}
						}
						if wrapped.len > 4 && expand_tool_results {
							lines << RenderLine{
								text:  '  │ (ctrl+o to collapse)'
								color: 'dim'
							}
						}
					} else {
						hidden := wrapped.len - 4
						lines << RenderLine{
							text:  '  │ ... (${hidden} lines)'
							color: 'dim'
						}
						for line_idx in (wrapped.len - 4) .. wrapped.len {
							lines << RenderLine{
								text:  '  │ ${wrapped[line_idx]}'
								color: 'tool_running'
							}
						}
					}
				}
			}
		}
	} else if is_loading {
		// Loading indicator is drawn separately, not here
	}
	if lines.len <= max_lines {
		return lines
	}
	return lines[lines.len - max_lines..]
}

pub struct VisibleWindow {
pub:
	lines       []RenderLine
	indicator   string
	indent_rows int
}

pub fn calculate_visible_window(all_lines []RenderLine, chat_height int, scroll_offset int) VisibleWindow {
	if all_lines.len <= chat_height {
		return VisibleWindow{
			lines:       all_lines
			indicator:   ''
			indent_rows: 0
		}
	}

	// Clamp scroll_offset
	mut clamped := scroll_offset
	mut max_offset := all_lines.len - chat_height
	if clamped > max_offset {
		clamped = max_offset
	}
	if clamped < 0 {
		clamped = 0
	}

	// Calculate visible window
	mut start_row := all_lines.len - chat_height - clamped
	if start_row < 0 {
		start_row = 0
	}
	mut end_row := start_row + chat_height
	if end_row > all_lines.len {
		end_row = all_lines.len
	}

	mut indent_rows := 0
	mut indicator := ''
	if clamped > 0 {
		indicator = '↓ ${clamped} lines (scroll down to bottom)'
		indent_rows = 1
	}

	return VisibleWindow{
		lines:       all_lines[start_row..end_row]
		indicator:   indicator
		indent_rows: indent_rows
	}
}
