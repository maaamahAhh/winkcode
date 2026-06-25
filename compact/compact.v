module compact

import llm

// compact_threshold is the approximate token count that triggers auto-compaction.
// Roughly 100k tokens (~400k characters).
const compact_threshold = 100_000

// recent_messages_to_keep is how many recent messages survive compaction intact.
const recent_messages_to_keep = 8

// compact_prompt is injected as a user message to the LLM for summarization.
const compact_prompt = '
Summarize this conversation concisely. Focus on:
1. What the user asked for and any feedback given
2. Key files read, edited, or created
3. Errors encountered and how they were fixed
4. Decisions made and current state of the work
5. Pending tasks or next steps

Be specific with file names and code snippets where they matter. Do NOT include tool call mechanics or terminal output.'

// estimate_tokens approximates total tokens in a message list (~4 chars per token).
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

// should_compact returns true if the conversation is long enough to compact.
pub fn should_compact(messages []llm.Message) bool {
	if messages.len <= recent_messages_to_keep {
		return false
	}
	// Also don't compact if even the recent messages alone exceed the threshold
	mut keep_start := messages.len - recent_messages_to_keep
	if keep_start < 0 {
		keep_start = 0
	}
	if estimate_tokens(messages[keep_start..]) > compact_threshold {
		return false
	}
	return estimate_tokens(messages) > compact_threshold
}

// compact replaces older messages with a summary, keeping only the most recent ones.
// It makes a blocking API call to generate the summary.
pub fn compact(mut a llm.Client) ! {
	if !should_compact(a.messages) {
		return
	}

	// Split: keep recent, summarize old
	mut keep_start := a.messages.len - recent_messages_to_keep
	if keep_start < 0 {
		keep_start = 0
	}
	mut recent := a.messages[keep_start..]
	mut old := a.messages[..keep_start]

	if old.len == 0 {
		return
	}

	// Build conversation text for summarization
	mut conversation_text := ''
	for msg in old {
		match msg.role {
			'user' {
				if msg.text.len > 0 {
					conversation_text += 'User: ${msg.text}\n\n'
				}
				for block in msg.content {
					match block.typ {
						'tool_result' {
							preview := if block.content.len > 500 {
								block.content[..500] + '...[truncated]'
							} else {
								block.content
							}
							conversation_text += 'Tool result: ${preview}\n\n'
						}
						else {}
					}
				}
			}
			'assistant' {
				if msg.text.len > 0 {
					conversation_text += 'Assistant: ${msg.text}\n\n'
				}
				for block in msg.content {
					if block.typ == 'text' && block.text.len > 0 {
						conversation_text += 'Assistant: ${block.text}\n\n'
					}
				}
			}
			else {}
		}
	}

	// Truncate conversation text if it's still too long
	if conversation_text.len > 200_000 {
		conversation_text = conversation_text[..200_000] + '\n\n...[earlier conversation truncated]'
	}

	// Save recent messages and clear
	mut saved_recent := []llm.Message{cap: recent.len}
	for msg in recent {
		saved_recent << msg
	}

	// Temporarily disable tools for compaction
	original_tool_schemas := a.tool_schemas
	a.tool_schemas = '[]'

	// Build compact request message
	a.messages = [
		llm.Message{
			role: 'user'
			text: '${compact_prompt}\n\n--- Conversation to summarize ---\n\n${conversation_text}'
		},
	]

	// Call API to get summary (non-streaming via result.text)
	result := a.chat_stream('', fn (_ string) {}, fn (_ llm.ToolCall) {}, fn (_ string) {}) or {
		a.tool_schemas = original_tool_schemas
		mut restored := []llm.Message{cap: old.len + saved_recent.len}
		restored << old
		restored << saved_recent
		a.messages = restored
		return error('compaction failed: ${err}')
	}

	// Restore tool schemas
	a.tool_schemas = original_tool_schemas

	// Build new message list: boundary marker + summary + recent messages
	summary := result.text.trim_space()
	if summary.len == 0 {
		mut restored := []llm.Message{cap: old.len + saved_recent.len}
		restored << old
		restored << saved_recent
		a.messages = restored
		return
	}

	boundary := llm.Message{
		role: 'user'
		text: '[Context was compacted. Earlier conversation summarized below.]\n\n${summary}'
	}
	a.messages = [
		boundary,
	]
	a.messages << saved_recent
}
