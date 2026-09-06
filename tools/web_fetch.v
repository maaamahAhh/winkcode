module tools

import os
import strings
import net.http

fn decode_html_entities(s string) string {
	mut text := s.replace('&amp;', '&')
		.replace('&lt;', '<')
		.replace('&gt;', '>')
		.replace('&quot;', '"')
		.replace('&#39;', "'")
		.replace('&apos;', "'")
		.replace('&nbsp;', ' ')
		.replace('&#0183;', '·')
		.replace('&copy;', '©')
		.replace('&reg;', '®')
		.replace('&trade;', '™')
		.replace('&mdash;', '—')
		.replace('&ndash;', '–')
	return text
}

pub fn find_tag_end(html string, start int) int {
	mut in_quote := u8(0)
	mut escaped := false
	for i := start; i < html.len; i++ {
		c := html[i]
		if escaped {
			escaped = false
			continue
		}
		if c == `\\` && in_quote != 0 {
			escaped = true
			continue
		}
		if in_quote != 0 {
			if c == in_quote {
				in_quote = 0
			}
		} else if c == `"` || c == `'` {
			in_quote = c
		} else if c == `>` {
			return i
		}
	}
	return -1
}

pub fn strip_html_block(html string, tag string) string {
	lower := html.to_lower()
	open_tag := '<${tag.to_lower()}'
	close_tag := '</${tag.to_lower()}'

	mut res := html
	mut lower_res := lower
	mut cursor := 0

	for {
		if cursor >= lower_res.len {
			break
		}
		start := lower_res.index_after(open_tag, cursor) or { break }
		if start + open_tag.len < lower_res.len {
			next_c := lower_res[start + open_tag.len]
			if next_c != ` ` && next_c != `>` && next_c != `\n` && next_c != `\t` && next_c != `/` {
				cursor = start + 1
				continue
			}
		}
		close_start := lower_res.index_after(close_tag, start) or { break }
		close_end := find_tag_end(lower_res, close_start)
		if close_end == -1 {
			break
		}
		res = res[..start] + ' ' + res[close_end + 1..]
		lower_res = lower_res[..start] + ' ' + lower_res[close_end + 1..]
		cursor = start
	}
	return res
}

pub fn clean_html_to_markdown(raw_html string, url string) string {
	mut html := raw_html

	// 1. Extract <title>
	mut title := ''
	lower_html := html.to_lower()
	if t_start := lower_html.index('<title') {
		t_open := find_tag_end(html, t_start)
		if t_open != -1 {
			if t_close := lower_html.index_after('</title>', t_open) {
				title = html[t_open + 1..t_close].trim_space()
			}
		}
	}

	// 2. Strip head block completely so metadata doesn't clutter content
	html = strip_html_block(html, 'head')

	// 3. Strip non-content blocks
	html = strip_html_block(html, 'script')
	html = strip_html_block(html, 'style')
	html = strip_html_block(html, 'noscript')
	html = strip_html_block(html, 'svg')
	html = strip_html_block(html, 'iframe')
	html = strip_html_block(html, 'nav')
	html = strip_html_block(html, 'footer')
	html = strip_html_block(html, 'header')
	html = strip_html_block(html, 'aside')
	html = strip_html_block(html, 'button')
	html = strip_html_block(html, 'form')

	// 4. Strip comments <!-- ... -->
	for {
		start := html.index('<!--') or { break }
		end := html.index_after('-->', start) or { break }
		html = html[..start] + html[end + 3..]
	}

	// 5. Convert links: <a ... href="..." ...>text</a> -> [text](href)
	mut link_sb := strings.new_builder(html.len)
	mut cursor := 0
	lower_html_links := html.to_lower()
	for cursor < html.len {
		if a_start := lower_html_links.index_after('<a ', cursor) {
			link_sb.write_string(html[cursor..a_start])
			a_tag_end := find_tag_end(html, a_start)
			if a_tag_end == -1 {
				link_sb.write_string(html[a_start..a_start + 3])
				cursor = a_start + 3
				continue
			}
			a_tag_str := html[a_start..a_tag_end]
			a_close := lower_html_links.index_after('</a>', a_tag_end) or {
				link_sb.write_string(html[a_start..a_tag_end + 1])
				cursor = a_tag_end + 1
				continue
			}
			link_text := html[a_tag_end + 1..a_close].trim_space()

			mut href := ''
			if h_idx := a_tag_str.index('href="') {
				h_start := h_idx + 6
				if h_end := a_tag_str.index_after('"', h_start) {
					href = a_tag_str[h_start..h_end]
				}
			} else if h_idx_single := a_tag_str.index("href='") {
				h_start := h_idx_single + 6
				if h_end := a_tag_str.index_after("'", h_start) {
					href = a_tag_str[h_start..h_end]
				}
			}

			if href.len > 0 && link_text.len > 0 && !href.starts_with('javascript:') {
				link_sb.write_string('[${link_text}](${href})')
			} else if link_text.len > 0 {
				link_sb.write_string(link_text)
			}
			cursor = a_close + 4
		} else {
			link_sb.write_string(html[cursor..])
			break
		}
	}
	html = link_sb.str()

	// 6. Tokenize tags into Markdown structure using find_tag_end
	mut res_sb := strings.new_builder(html.len)
	mut i := 0
	for i < html.len {
		if html[i] == `<` {
			tag_end := find_tag_end(html, i)
			if tag_end == -1 {
				res_sb.write_u8(html[i])
				i++
				continue
			}
			tag_content := html[i + 1..tag_end].trim_space().to_lower()
			mut tag_name := ''
			for idx, c in tag_content {
				if (c == ` ` || c == `\t` || c == `\n` || c == `\r`) || (c == `/` && idx > 0) {
					break
				}
				tag_name += c.ascii_str()
			}

			match tag_name {
				'h1' { res_sb.write_string('\n\n# ') }
				'h2' { res_sb.write_string('\n\n## ') }
				'h3' { res_sb.write_string('\n\n### ') }
				'h4' { res_sb.write_string('\n\n#### ') }
				'h5' { res_sb.write_string('\n\n##### ') }
				'h6' { res_sb.write_string('\n\n###### ') }
				'/h1', '/h2', '/h3', '/h4', '/h5', '/h6' { res_sb.write_string('\n\n') }
				'p', '/p', 'div', '/div', 'section', '/section', 'article', '/article' {
					res_sb.write_string('\n\n')
				}
				'br' { res_sb.write_string('\n') }
				'hr' { res_sb.write_string('\n---\n') }
				'li' { res_sb.write_string('\n- ') }
				'/li' { res_sb.write_string('\n') }
				'pre' { res_sb.write_string('\n```\n') }
				'/pre' { res_sb.write_string('\n```\n') }
				'code', '/code' { res_sb.write_u8(`\``) }
				'b', 'strong', '/b', '/strong' { res_sb.write_string('**') }
				'i', 'em', '/i', '/em' { res_sb.write_u8(`*`) }
				'tr' { res_sb.write_string('\n') }
				'th', 'td' { res_sb.write_string(' | ') }
				else {}
			}
			i = tag_end + 1
		} else {
			res_sb.write_u8(html[i])
			i++
		}
	}

	raw_text := decode_html_entities(res_sb.str())

	// 7. Collapse empty lines
	lines := raw_text.split('\n')
	mut clean_lines := []string{}
	mut prev_empty := false
	for line in lines {
		trimmed := line.trim_space()
		if trimmed.len == 0 {
			if !prev_empty && clean_lines.len > 0 {
				clean_lines << ''
				prev_empty = true
			}
		} else {
			clean_lines << trimmed
			prev_empty = false
		}
	}

	mut body := clean_lines.join('\n')
	max_len := 30000
	if body.len > max_len {
		body = body[..max_len] + '\n\n...[Content truncated (${body.len} chars total)]...'
	}

	mut header := ''
	if title.len > 0 {
		header = '# ${title}\n\nSource URL: ${url}\n\n'
	} else {
		header = 'Source URL: ${url}\n\n'
	}
	return header + body
}

pub fn convert_github_url_to_raw(url string) string {
	mut prefix := ''
	if url.starts_with('https://github.com/') {
		prefix = 'https://github.com/'
	} else if url.starts_with('http://github.com/') {
		prefix = 'http://github.com/'
	} else {
		return url
	}
	path := url[prefix.len..]
	parts := path.split('/')
	if parts.len >= 4 && parts[2] == 'blob' {
		owner := parts[0]
		repo := parts[1]
		rest := parts[3..].join('/')
		return 'https://raw.githubusercontent.com/${owner}/${repo}/${rest}'
	}
	return url
}

pub fn is_local_or_private_url(url string) bool {
	lower := url.to_lower()
	if lower.contains('://localhost') || lower.contains('://127.0.0.1') || lower.contains('://0.0.0.0') {
		return true
	}
	if lower.contains('://192.168.') || lower.contains('://10.') {
		return true
	}
	for i in 16 .. 32 {
		if lower.contains('://172.${i}.') {
			return true
		}
	}
	return false
}

fn fetch_via_jina(url string) ?string {
	if is_local_or_private_url(url) {
		return none
	}
	jina_url := 'https://r.jina.ai/${url}'
	mut custom_headers := map[http.CommonHeader]string{}
	custom_headers[.accept] = 'text/markdown'
	custom_headers[.user_agent] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
	api_key := os.getenv('JINA_API_KEY').trim_space()
	if api_key.len > 0 {
		custom_headers[.authorization] = 'Bearer ${api_key}'
	}

	mut req := http.Request{
		url:    jina_url
		method: .get
		header: http.new_header_from_map(custom_headers)
	}
	resp := req.do() or {
		return none
	}

	if resp.status_code != 200 {
		return none
	}

	trimmed_body := resp.body.trim_space()
	if trimmed_body.len == 0 {
		return none
	}

	if trimmed_body.starts_with('AbuseAlleviationError') || trimmed_body.contains('Suspicious action: Request to local network') {
		return none
	}

	return resp.body
}

pub fn tool_web_fetch(args map[string]string) ToolResult {
	raw_url := args['url'].trim_space()
	if raw_url.len == 0 {
		return ToolResult{
			content:  'Error: url parameter is required for web_fetch'
			is_error: true
		}
	}

	if !raw_url.starts_with('http://') && !raw_url.starts_with('https://') {
		return ToolResult{
			content:  'Error: invalid URL "${raw_url}". Must start with http:// or https://'
			is_error: true
		}
	}

	// 1. Rewrite GitHub blob URLs to raw.githubusercontent.com
	url := convert_github_url_to_raw(raw_url)

	raw_mode := args['raw'] == 'true'
	local_only := args['local'] == 'true'

	// 2. If not raw mode, not local-only, and not a raw code URL, try Jina Reader first
	if !raw_mode && !local_only && !url.starts_with('https://raw.githubusercontent.com/') {
		if jina_md := fetch_via_jina(url) {
			return ToolResult{
				content:  truncate_output(jina_md, 40000)
				is_error: false
			}
		}
	}

	// 3. Fallback: local HTTP fetch
	mut req := http.Request{
		url:    url
		method: .get
		header: http.new_header_from_map({
			.accept:          'text/html,application/xhtml+xml,application/xml;q=0.9,text/plain,text/markdown,application/json;q=0.8,*/*;q=0.7'
			.accept_language: 'en-US,en;q=0.9,zh-CN;q=0.8'
			.user_agent:      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
		})
	}

	resp := req.do() or {
		return ToolResult{
			content:  'Error fetching ${url}: ${err}'
			is_error: true
		}
	}

	if resp.status_code >= 400 {
		return ToolResult{
			content:  'HTTP error ${resp.status_code}: ${resp.status_msg}'
			is_error: true
		}
	}

	if raw_mode {
		return ToolResult{
			content:  truncate_output(resp.body, 40000)
			is_error: false
		}
	}

	// Direct text passthrough for markdown, plain text, and json
	content_type := (resp.header.get(.content_type) or { '' }).to_lower()
	if content_type.contains('text/markdown') || content_type.contains('text/plain') || content_type.contains('application/json') || url.starts_with('https://raw.githubusercontent.com/') {
		return ToolResult{
			content:  truncate_output(resp.body, 40000)
			is_error: false
		}
	}

	markdown := clean_html_to_markdown(resp.body, url)
	return ToolResult{
		content:  markdown
		is_error: false
	}
}
