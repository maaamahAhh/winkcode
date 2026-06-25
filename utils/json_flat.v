module utils

// parse_flat_json parses a flat JSON object string into a map[string]string.
// It handles string values (with escape sequences), numbers, booleans, and null.
// Nested objects/arrays are not supported.
pub fn parse_flat_json(s string) !map[string]string {
	mut result := map[string]string{}
	if s.len == 0 {
		return result
	}

	mut i := 0
	for i < s.len {
		// Skip whitespace and commas
		for i < s.len && (s[i] == ` ` || s[i] == `\n` || s[i] == `\r` || s[i] == `\t` || s[i] == `,`) {
			i++
		}
		if i >= s.len {
			break
		}

		// Expect key (quoted string)
		if s[i] != `"` {
			return error('expected key at position ${i}, got ${s[i].ascii_str()}')
		}
		i++
		mut key_bytes := []u8{}
		for i < s.len && s[i] != `"` {
			if s[i] == `\\` && i + 1 < s.len {
				next := s[i + 1]
				match next {
					`"` { key_bytes << `"` }
					`\\` { key_bytes << `\\` }
					`n` { key_bytes << `\n`.bytes() }
					`t` { key_bytes << `\t`.bytes() }
					`r` { key_bytes << `\r`.bytes() }
				`/` { key_bytes << `/` }
					else {
						key_bytes << `\\`
						key_bytes << next
					}
				}
				i += 2
			} else {
				key_bytes << s[i]
				i++
			}
		}
		key := key_bytes.bytestr()
		i++ // skip closing quote

		// Skip whitespace and colon
		for i < s.len && (s[i] == ` ` || s[i] == `\n` || s[i] == `\r` || s[i] == `\t` || s[i] == `:`) {
			i++
		}

		if i >= s.len {
			break
		}

		// Parse value
		if s[i] == `"` {
			i++
			mut val_bytes := []u8{}
			for i < s.len && s[i] != `"` {
				if s[i] == `\\` && i + 1 < s.len {
					next := s[i + 1]
					match next {
						`"` { val_bytes << `"` }
						`\\` { val_bytes << `\\` }
						`n` { val_bytes << `\n`.bytes() }
						`t` { val_bytes << `\t`.bytes() }
						`r` { val_bytes << `\r`.bytes() }
					`/` { val_bytes << `/` }
						else {
							val_bytes << `\\`
							val_bytes << next
						}
					}
					i += 2
				} else {
					val_bytes << s[i]
					i++
				}
			}
			result[key] = val_bytes.bytestr()
			i++ // skip closing quote
		} else if s[i] == `t` {
			result[key] = 'true'
			i += 4
		} else if s[i] == `f` {
			result[key] = 'false'
			i += 5
		} else if s[i] == `n` {
			result[key] = ''
			i += 4
		} else if s[i] == `-` || (s[i] >= `0` && s[i] <= `9`) {
			num_start := i
			for i < s.len && s[i] != `,` && s[i] != `}` && s[i] != ` ` && s[i] != `\n` && s[i] != `\r` && s[i] != `\t` {
				i++
			}
			result[key] = s[num_start..i]
		} else {
			return error('unexpected character in JSON at position ${i}: ${s[i].ascii_str()}')
		}
	}

	return result
}
