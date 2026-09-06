module utils

struct FlatJsonParser {
	s string
mut:
	i int
}

fn (mut p FlatJsonParser) skip_delimiters() {
	for p.i < p.s.len {
		ch := p.s[p.i]
		if ch == ` ` || ch == `\n` || ch == `\r` || ch == `\t` || ch == `,` || ch == `}` || ch == `{` {
			p.i++
		} else {
			break
		}
	}
}

fn (mut p FlatJsonParser) skip_whitespace_and_colon() {
	for p.i < p.s.len {
		ch := p.s[p.i]
		if ch == ` ` || ch == `\n` || ch == `\r` || ch == `\t` || ch == `:` {
			p.i++
		} else {
			break
		}
	}
}

fn (mut p FlatJsonParser) parse_string() !string {
	if p.i >= p.s.len || p.s[p.i] != `"` {
		got := if p.i < p.s.len { p.s[p.i].ascii_str() } else { 'EOF' }
		return error('expected quoted string, got ${got}')
	}
	p.i++
	mut bytes := []u8{}
	for p.i < p.s.len && p.s[p.i] != `"` {
		if p.s[p.i] == `\\` && p.i + 1 < p.s.len {
			next := p.s[p.i + 1]
			match next {
				`"` {
					bytes << `"`
					p.i += 2
				}
				`\\` {
					bytes << `\\`
					p.i += 2
				}
				`n` {
					bytes << `\n`.bytes()
					p.i += 2
				}
				`t` {
					bytes << `\t`.bytes()
					p.i += 2
				}
				`r` {
					bytes << `\r`.bytes()
					p.i += 2
				}
				`/` {
					bytes << `/`
					p.i += 2
				}
				`u` {
					p.i = append_unicode_escape(mut bytes, p.s, p.i)
				}
				else {
					bytes << `\\`
					bytes << next
					p.i += 2
				}
			}
		} else {
			bytes << p.s[p.i]
			p.i++
		}
	}
	if p.i < p.s.len && p.s[p.i] == `"` {
		p.i++
	}
	return bytes.bytestr()
}

fn (mut p FlatJsonParser) parse_balanced_block() string {
	open_ch := p.s[p.i]
	close_ch := if open_ch == `[` { u8(`]`) } else { u8(`}`) }
	start := p.i
	mut depth := 0
	mut in_str := false
	mut is_esc := false
	for p.i < p.s.len {
		ch := p.s[p.i]
		if in_str {
			if is_esc {
				is_esc = false
			} else if ch == `\\` {
				is_esc = true
			} else if ch == `"` {
				in_str = false
			}
		} else {
			if ch == `"` {
				in_str = true
			} else if ch == open_ch {
				depth++
			} else if ch == close_ch {
				depth--
				if depth == 0 {
					p.i++
					break
				}
			}
		}
		p.i++
	}
	return p.s[start..p.i]
}

fn (mut p FlatJsonParser) parse_value() !string {
	if p.i >= p.s.len {
		return ''
	}
	ch := p.s[p.i]
	if ch == `"` {
		return p.parse_string()
	} else if ch == `t` {
		p.i += 4
		return 'true'
	} else if ch == `f` {
		p.i += 5
		return 'false'
	} else if ch == `n` {
		p.i += 4
		return ''
	} else if ch == `-` || (ch >= `0` && ch <= `9`) {
		start := p.i
		for p.i < p.s.len {
			c := p.s[p.i]
			if c != `,` && c != `}` && c != ` ` && c != `\n` && c != `\r` && c != `\t` {
				p.i++
			} else {
				break
			}
		}
		return p.s[start..p.i]
	} else if ch == `[` || ch == `{` {
		return p.parse_balanced_block()
	}
	ch_str := ch.ascii_str()
	return error('unexpected character in JSON at position ${p.i}: ${ch_str}')
}

// parse_flat_json parses a flat or single-level JSON object string into a map[string]string.
// It handles string values (with escape sequences), numbers, booleans, null, and captures
// nested objects/arrays as raw JSON strings.
pub fn parse_flat_json(s string) !map[string]string {
	mut result := map[string]string{}
	mut trimmed := s.trim_space()
	if trimmed.len == 0 {
		return result
	}
	if trimmed.starts_with('{') {
		trimmed = trimmed[1..]
	}
	if trimmed.ends_with('}') {
		trimmed = trimmed[..trimmed.len - 1]
	}

	mut parser := FlatJsonParser{
		s: trimmed
		i: 0
	}

	for parser.i < parser.s.len {
		parser.skip_delimiters()
		if parser.i >= parser.s.len {
			break
		}

		key := parser.parse_string()!
		parser.skip_whitespace_and_colon()
		if parser.i >= parser.s.len {
			result[key] = ''
			break
		}

		val := parser.parse_value()!
		result[key] = val
	}

	return result
}

// append_unicode_escape decodes a \uXXXX escape (with an optional surrogate
// pair) at s[i..], appends its UTF-8 bytes, and returns the index after it.
pub fn append_unicode_escape(mut out []u8, s string, i int) int {
	if i + 5 >= s.len {
		out << `\\`
		out << `u`
		return i + 2
	}
	h0 := hex_digit(s[i + 2])
	h1 := hex_digit(s[i + 3])
	h2 := hex_digit(s[i + 4])
	h3 := hex_digit(s[i + 5])
	if h0 < 0 || h1 < 0 || h2 < 0 || h3 < 0 {
		out << `\\`
		out << `u`
		return i + 2
	}
	code := h0 * 4096 + h1 * 256 + h2 * 16 + h3
	// Surrogate pair (e.g. emoji): \uD83D\udcf1
	if code >= 0xd800 && code <= 0xdbff && i + 11 < s.len && s[i + 6] == `\\` && s[i + 7] == `u` {
		l0 := hex_digit(s[i + 8])
		l1 := hex_digit(s[i + 9])
		l2 := hex_digit(s[i + 10])
		l3 := hex_digit(s[i + 11])
		if l0 >= 0 && l1 >= 0 && l2 >= 0 && l3 >= 0 {
			lo := l0 * 4096 + l1 * 256 + l2 * 16 + l3
			if lo >= 0xdc00 && lo <= 0xdfff {
				cp := 0x10000 + (code - 0xd800) * 0x400 + (lo - 0xdc00)
				out << rune(cp).str().bytes()
				return i + 12
			}
		}
	}
	out << rune(code).str().bytes()
	return i + 6
}

fn hex_digit(ch u8) int {
	c := int(ch)
	return match true {
		c >= 48 && c <= 57 { c - 48 }
		c >= 97 && c <= 102 { c - 97 + 10 }
		c >= 65 && c <= 70 { c - 65 + 10 }
		else { -1 }
	}
}
