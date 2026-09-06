module compact

import llm
import strings
import json2

// reserve_tokens is reserved at the top of the context window for model response.
const reserve_tokens = 16_384

// keep_recent_tokens is the token budget reserved for recent conversation history.
const keep_recent_tokens = 20_000

// default_context_window is used if not explicitly configured in ModelConfig.
const default_context_window = 256_000

// summarization_system_prompt sets the role for the compaction engine.
const summarization_system_prompt = 'You are a context compaction engine for an AI coding assistant.
Summarize the conversation into a dense, high-signal structured state snapshot.
Omit conversational filler. Preserve all critical context so the assistant can continue without loss.

Structure your output strictly using these XML tags:
<state_snapshot>
<primary_intent>
[Core user goals, explicit requirements, and specific feedback/preferences]
</primary_intent>

<files_and_code>
[Specific file paths examined, created, or modified, with brief reasons and key code patterns]
</files_and_code>

<decisions_and_fixes>
[Important architectural decisions, errors encountered, and exact resolutions]
</decisions_and_fixes>

<pending_and_next_steps>
[Unfinished tasks, immediate next steps, and current state where work left off]
</pending_and_next_steps>
</state_snapshot>'

// estimate_tokens estimates token count (~4 characters per token).
pub fn estimate_tokens(messages []llm.Message) int {
	mut total := 0
	for msg in messages {
		total += msg.text.len
		for block in msg.content {
			total += block.text.len
			total += block.content.len
			total += block.input.len
		}
	}
	return total / 4
}

// should_compact reports whether conversation length exceeds the trigger threshold.
pub fn should_compact(client &llm.Client) bool {
	ctx_win := if client.context_window > 0 { client.context_window } else { default_context_window }
	threshold := ctx_win - reserve_tokens
	tokens := estimate_tokens(client.messages)
	return tokens > threshold && client.messages.len > 4
}

// find_safe_cut_point walks backwards from the latest message to reserve keep_budget tokens,
// ensuring the cut point lands strictly on a clean User message boundary (never splitting tool_use / tool_result).
fn find_safe_cut_point(messages []llm.Message, keep_budget int) int {
	if messages.len <= 2 {
		return 0
	}
	mut accumulated := 0
	mut target_idx := -1

	for i := messages.len - 1; i >= 0; i-- {
		msg := messages[i]
		mut msg_chars := msg.text.len
		for b in msg.content {
			msg_chars += b.text.len + b.content.len + b.input.len
		}
		accumulated += msg_chars / 4
		if accumulated >= keep_budget {
			target_idx = i
			break
		}
	}

	// If total conversation is smaller than keep_budget (e.g. manual /compact),
	// dynamically adapt: keep the latest user turn and summarize all prior turns.
	if target_idx <= 0 {
		mut user_turn_indices := []int{}
		for i, m in messages {
			if m.role == 'user' && !m.content.any(it.typ == 'tool_result') {
				user_turn_indices << i
			}
		}
		if user_turn_indices.len > 1 {
			return user_turn_indices.last()
		}
		return 0
	}

	// Align to clean turn boundary: find the nearest user message that is NOT a tool_result
	for idx := target_idx; idx < messages.len - 1; idx++ {
		m := messages[idx]
		if m.role == 'user' && !m.content.any(it.typ == 'tool_result') {
			return idx
		}
	}

	// Fallback: look backwards if not found forwards
	for idx := target_idx; idx > 0; idx-- {
		m := messages[idx]
		if m.role == 'user' && !m.content.any(it.typ == 'tool_result') {
			return idx
		}
	}

	return 0
}

// extract_file_ops collects file paths read or modified from tool calls in messages.
fn extract_file_ops(messages []llm.Message) ([]string, []string) {
	mut read_set := map[string]bool{}
	mut mod_set := map[string]bool{}

	for msg in messages {
		if msg.role == 'assistant' {
			for block in msg.content {
				if block.typ == 'tool_use' {
					match block.name {
						'read' {
							path := extract_path_arg(block.input)
							if path.len > 0 {
								read_set[path] = true
							}
						}
						'write', 'edit' {
							path := extract_path_arg(block.input)
							if path.len > 0 {
								mod_set[path] = true
							}
						}
						else {}
					}
				}
			}
		}
	}

	mut read_files := []string{}
	for f in read_set.keys() {
		if f !in mod_set {
			read_files << f
		}
	}
	read_files.sort()

	mut mod_files := mod_set.keys()
	mod_files.sort()

	return read_files, mod_files
}

fn extract_path_arg(input_json string) string {
	if input_json.len == 0 {
		return ''
	}
	data := json2.decode[map[string]string](input_json) or { return '' }
	return data['path'] or { data['filePath'] or { data['file_path'] or { '' } } }
}

// serialize_conversation formats historical messages into a compact plain text transcript for summarization.
fn serialize_conversation(messages []llm.Message) string {
	mut sb := strings.new_builder(4096)

	for msg in messages {
		match msg.role {
			'user' {
				if msg.text.len > 0 {
					sb.writeln('[User]: ${msg.text}\n')
				}
				for block in msg.content {
					if block.typ == 'tool_result' {
						preview := if block.content.len > 1500 {
							block.content[..1500] + '\n...[truncated]'
						} else {
							block.content
						}
						sb.writeln('[Tool Result]: ${preview}\n')
					}
				}
			}
			'assistant' {
				if msg.text.len > 0 {
					sb.writeln('[Assistant]: ${msg.text}\n')
				}
				for block in msg.content {
					match block.typ {
						'text' {
							if block.text.len > 0 {
								sb.writeln('[Assistant]: ${block.text}\n')
							}
						}
						'tool_use' {
							sb.writeln('[Tool Call]: ${block.name}(${block.input})\n')
						}
						else {}
					}
				}
			}
			else {}
		}
	}

	mut text := sb.str()
	if text.len > 250_000 {
		text = text[..250_000] + '\n\n...[earlier history truncated for summarization]'
	}
	return text
}

// compact executes context compaction, summarizing older history and retaining recent turns safely.
// Returns the generated summary text.
pub fn compact(mut a llm.Client, custom_instructions string) !string {
	if a.messages.len <= 2 {
		return error('context too small to compact')
	}

	cut_point := find_safe_cut_point(a.messages, keep_recent_tokens)
	if cut_point <= 0 || cut_point >= a.messages.len {
		return error('context too small to compact (need at least 2 conversational turns)')
	}

	mut old_msgs := a.messages[..cut_point]
	mut kept_msgs := a.messages[cut_point..]

	if old_msgs.len == 0 {
		return error('nothing to compact')
	}

	read_files, mod_files := extract_file_ops(old_msgs)
	transcript := serialize_conversation(old_msgs)

	mut prompt_sb := strings.new_builder(2048)
	prompt_sb.writeln(summarization_system_prompt)
	if custom_instructions.trim_space().len > 0 {
		prompt_sb.writeln('\nAdditional User Instructions:\n${custom_instructions.trim_space()}')
	}
	if mod_files.len > 0 {
		prompt_sb.writeln('\nModified Files in Scope:\n- ${mod_files.join('\n- ')}')
	}
	if read_files.len > 0 {
		prompt_sb.writeln('\nRead-Only Files in Scope:\n- ${read_files.join('\n- ')}')
	}
	prompt_sb.writeln('\n--- Conversation History to Summarize ---\n')
	prompt_sb.writeln(transcript)

	// Use an isolated client instance so live conversation state is never mutated if compaction fails
	mut comp_client := a.clone_clean()
	comp_client.tool_schemas = '[]'
	comp_client.system_prompt = summarization_system_prompt

	result := comp_client.chat_stream(prompt_sb.str(), fn (_ string) {}, fn (_ llm.ToolCall) {},
		fn (_ string) {}, fn (_ string, _ string) {}) or {
		return error('compaction API call failed: ${err}')
	}

	summary := result.text.trim_space()
	if summary.len == 0 {
		return error('compaction generated empty summary')
	}

	summary_prefix := '[Context was compacted. Prior conversation summarized below.]\n\n${summary}'

	// If the first kept message is already a user turn, prepend summary to maintain strict user -> assistant alternation
	if kept_msgs.len > 0 && kept_msgs[0].role == 'user' {
		mut first := kept_msgs[0]
		if first.text.len > 0 {
			first.text = '${summary_prefix}\n\n${first.text}'
		} else if first.content.len > 0 && first.content[0].typ == 'text' {
			first.content[0].text = '${summary_prefix}\n\n${first.content[0].text}'
		} else {
			mut new_blocks := [llm.ContentBlock{
				typ: 'text'
				text: summary_prefix
			}]
			for b in first.content {
				new_blocks << b
			}
			first.content = new_blocks
		}
		a.messages = [first]
		for i := 1; i < kept_msgs.len; i++ {
			a.messages << kept_msgs[i]
		}
	} else {
		boundary := llm.Message{
			role: 'user'
			text: summary_prefix
		}
		a.messages = [boundary]
		for m in kept_msgs {
			a.messages << m
		}
	}

	return summary
}
