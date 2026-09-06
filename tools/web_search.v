module tools

import encoding.base64
import net.http
import net.urllib
import os
import x.json2

struct SearchItem {
pub mut:
	title   string
	url     string
	snippet string
	engines []string
	score   f32
}

const tracking_params = [
	'utm_source',
	'utm_medium',
	'utm_campaign',
	'utm_term',
	'utm_content',
	'gclid',
	'fbclid',
	'msclkid',
	'spm',
	'_hsenc',
	'_hsmi',
]

fn clean_html_tags_and_entities(s string) string {
	mut res := []u8{}
	mut in_tag := false
	for i := 0; i < s.len; i++ {
		c := s[i]
		if c == `<` {
			in_tag = true
		} else if c == `>` {
			in_tag = false
		} else if !in_tag {
			res << c
		}
	}
	mut text := res.bytestr()
	text = text.replace('&amp;', '&')
		.replace('&lt;', '<')
		.replace('&gt;', '>')
		.replace('&quot;', '"')
		.replace('&#39;', "'")
		.replace('&apos;', "'")
		.replace('&nbsp;', ' ')
		.replace('&#0183;', '·')
	return text.trim_space()
}

fn normalize_search_url(raw_url string) string {
	mut u := raw_url.trim_space()
	if q_idx := u.index('?') {
		base := u[..q_idx]
		query_str := u[q_idx + 1..]
		pairs := query_str.split('&')
		mut kept := []string{}
		for p in pairs {
			if p.len == 0 {
				continue
			}
			key := p.split('=')[0].to_lower()
			if key !in tracking_params {
				kept << p
			}
		}
		if kept.len > 0 {
			u = '${base}?${kept.join('&')}'
		} else {
			u = base
		}
	}
	if u.ends_with('/') {
		u = u[..u.len - 1]
	}
	return u
}

fn unwrap_ddg_url(raw_url string) string {
	if idx := raw_url.index('uddg=') {
		mut rest := raw_url[idx + 5..]
		if amp := rest.index('&') {
			rest = rest[..amp]
		}
		return urllib.query_unescape(rest) or { raw_url }
	}
	return raw_url
}

fn unwrap_bing_url(raw_url string) string {
	clean_url := raw_url.replace('&amp;', '&')
	if !clean_url.contains('bing.com/ck/a') {
		return clean_url
	}
	mut u_idx := clean_url.index('u=a1') or { clean_url.index('&u=a1') or { return clean_url } }
	mut encoded := clean_url[u_idx..]
	if a1_pos := encoded.index('a1') {
		encoded = encoded[a1_pos + 2..]
	}
	if amp := encoded.index('&') {
		encoded = encoded[..amp]
	}
	if q := encoded.index('"') {
		encoded = encoded[..q]
	}
	mut s := encoded.replace('-', '+').replace('_', '/')
	pad := (4 - (s.len % 4)) % 4
	s += '='.repeat(pad)
	decoded := base64.decode_str(s)
	if decoded.len > 0 && decoded.starts_with('http') {
		return decoded
	}
	return clean_url
}

fn search_duckduckgo(query string, limit int) []SearchItem {
	encoded_q := urllib.query_escape(query)
	post_data := 'q=${encoded_q}&b=&kl=wt-wt'

	mut req := http.Request{
		url:    'https://html.duckduckgo.com/html/'
		method: .post
		data:   post_data
		header: http.new_header_from_map({
			.content_type: 'application/x-www-form-urlencoded'
			.referer:      'https://html.duckduckgo.com/'
			.user_agent:   'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
		})
	}
	resp := req.do() or { return []SearchItem{} }
	if resp.status_code != 200 {
		return []SearchItem{}
	}

	html := resp.body
	mut items := []SearchItem{}
	mut cursor := 0
	for items.len < limit {
		title_idx := html.index_after('result__title', cursor) or { break }
		a_idx := html.index_after('<a', title_idx) or { break }
		href_idx := html.index_after('href="', a_idx) or { break }
		href_val_start := href_idx + 6
		href_val_end := html.index_after('"', href_val_start) or { break }
		raw_url := html[href_val_start..href_val_end]
		url := normalize_search_url(unwrap_ddg_url(raw_url))

		a_close := html.index_after('</a>', href_val_end) or { break }
		title := clean_html_tags_and_entities(html[href_val_end + 1..a_close])

		mut snippet := ''
		if snip_idx := html.index_after('result__snippet', a_close) {
			if snip_tag_close := html.index_after('>', snip_idx) {
				if snip_end := html.index_after('</a>', snip_tag_close) {
					snippet = clean_html_tags_and_entities(html[snip_tag_close + 1..snip_end])
				}
			}
		}

		if title.len > 0 && url.len > 0 && url.starts_with('http') {
			items << SearchItem{
				title:   title
				url:     url
				snippet: snippet
				engines: ['DuckDuckGo']
			}
		}
		cursor = a_close
	}
	return items
}

fn search_bing(query string, limit int) []SearchItem {
	encoded_q := urllib.query_escape(query)
	url := 'https://www.bing.com/search?q=${encoded_q}'

	mut req := http.Request{
		url:    url
		method: .get
		header: http.new_header_from_map({
			.accept:          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
			.accept_language: 'en-US,en;q=0.9,zh-CN;q=0.8'
			.user_agent:      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
		})
	}
	resp := req.do() or { return []SearchItem{} }
	if resp.status_code != 200 {
		return []SearchItem{}
	}

	html := resp.body
	mut items := []SearchItem{}
	mut cursor := 0
	for items.len < limit {
		card_idx := html.index_after('class="b_algo"', cursor) or { break }
		h2_idx := html.index_after('<h2', card_idx) or { break }
		a_idx := html.index_after('<a', h2_idx) or { break }
		href_idx := html.index_after('href="', a_idx) or { break }
		href_start := href_idx + 6
		href_end := html.index_after('"', href_start) or { break }
		raw_url := html[href_start..href_end]
		parsed_url := normalize_search_url(unwrap_bing_url(raw_url))

		a_tag_end := html.index_after('>', a_idx) or { break }
		a_close := html.index_after('</a>', a_tag_end) or { break }
		title := clean_html_tags_and_entities(html[a_tag_end + 1..a_close])

		mut snippet := ''
		if cap_idx := html.index_after('class="b_caption"', card_idx) {
			if p_idx := html.index_after('<p', cap_idx) {
				if p_open := html.index_after('>', p_idx) {
					if p_close := html.index_after('</p>', p_open) {
						snippet = clean_html_tags_and_entities(html[p_open + 1..p_close])
					}
				}
			}
		}

		if title.len > 0 && parsed_url.len > 0 && parsed_url.starts_with('http') {
			items << SearchItem{
				title:   title
				url:     parsed_url
				snippet: snippet
				engines: ['Bing']
			}
		}
		cursor = a_close
	}
	return items
}

fn search_exa(query string, limit int, api_key string) []SearchItem {
	escaped_query := query.replace('\\', '\\\\').replace('"', '\\"')
	req_body := '{"query":"${escaped_query}","numResults":${limit},"type":"auto","contents":{"text":{"maxCharacters":300}}}'

	mut req := http.Request{
		url:    'https://api.exa.ai/search'
		method: .post
		data:   req_body
		header: http.new_header_from_map({
			.content_type: 'application/json'
		})
	}
	req.header.add_custom('x-api-key', api_key) or {}

	resp := req.do() or { return []SearchItem{} }
	if resp.status_code != 200 {
		return []SearchItem{}
	}

	raw := json2.decode[json2.Any](resp.body) or { return []SearchItem{} }
	root_obj := raw.as_map()
	results_val := root_obj['results'] or { return []SearchItem{} }
	results_arr := results_val.as_array()

	mut items := []SearchItem{}
	for res_val in results_arr {
		r_map := res_val.as_map()
		title := r_map['title'] or { json2.Any('') }.str()
		url := r_map['url'] or { json2.Any('') }.str()
		mut text := r_map['text'] or { json2.Any('') }.str()
		if text.len == 0 {
			if highlights := r_map['highlights'] {
				h_arr := highlights.as_array()
				if h_arr.len > 0 {
					text = h_arr[0].str()
				}
			}
		}
		if url.len > 0 {
			items << SearchItem{
				title:   if title.len > 0 { title } else { url }
				url:     normalize_search_url(url)
				snippet: text.trim_space()
				engines: ['Exa']
			}
		}
	}
	return items
}

fn search_builtin_aggregated(query string, limit int) []SearchItem {
	t_ddg := spawn search_duckduckgo(query, limit)
	t_bing := spawn search_bing(query, limit)

	ddg_results := t_ddg.wait()
	bing_results := t_bing.wait()

	mut merged := map[string]SearchItem{}
	mut url_order := []string{}

	// Add DDG results
	for rank, item in ddg_results {
		rrf_score := 1.0 / f32(rank + 1)
		if item.url in merged {
			mut existing := merged[item.url]
			existing.score += rrf_score
			if 'DuckDuckGo' !in existing.engines {
				existing.engines << 'DuckDuckGo'
			}
			if existing.snippet.len == 0 && item.snippet.len > 0 {
				existing.snippet = item.snippet
			}
			merged[item.url] = existing
		} else {
			mut new_item := item
			new_item.score = rrf_score
			merged[item.url] = new_item
			url_order << item.url
		}
	}

	// Add Bing results
	for rank, item in bing_results {
		rrf_score := 1.0 / f32(rank + 1)
		if item.url in merged {
			mut existing := merged[item.url]
			existing.score += rrf_score
			if 'Bing' !in existing.engines {
				existing.engines << 'Bing'
			}
			if existing.snippet.len == 0 && item.snippet.len > 0 {
				existing.snippet = item.snippet
			}
			merged[item.url] = existing
		} else {
			mut new_item := item
			new_item.score = rrf_score
			merged[item.url] = new_item
			url_order << item.url
		}
	}

	mut list := []SearchItem{}
	for u in url_order {
		list << merged[u]
	}

	list.sort(a.score > b.score)

	if list.len > limit {
		return list[..limit]
	}
	return list
}

fn format_search_output(query string, items []SearchItem, provider_note string) string {
	if items.len == 0 {
		return 'No results found for "${query}".'
	}

	mut sb := []string{}
	sb << 'Search results for "${query}" (${provider_note}):\n'
	for i, item in items {
		engine_str := item.engines.join(', ')
		sb << '${i + 1}. [${item.title}](${item.url})'
		sb << '   URL: ${item.url}'
		if engine_str.len > 0 {
			sb << '   Source: ${engine_str}'
		}
		if item.snippet.len > 0 {
			sb << '   Snippet: ${item.snippet}'
		}
		sb << ''
	}
	return sb.join('\n').trim_space()
}

pub fn tool_web_search(args map[string]string) ToolResult {
	query := args['query'].trim_space()
	if query.len == 0 {
		return ToolResult{
			content:  'Error: query parameter is required for web_search'
			is_error: true
		}
	}

	mut limit := if args['limit'] != '' { args['limit'].int() } else { 8 }
	if limit <= 0 {
		limit = 8
	} else if limit > 20 {
		limit = 20
	}

	// 1. If EXA_API_KEY is configured, try Exa first
	exa_key := os.getenv('EXA_API_KEY').trim_space()
	if exa_key.len > 0 {
		exa_items := search_exa(query, limit, exa_key)
		if exa_items.len > 0 {
			return ToolResult{
				content:  format_search_output(query, exa_items, 'Exa Neural Search')
				is_error: false
			}
		}
		// Fallback to built-in metasearch aggregator if Exa fails or returns empty
	}

	// 2. Built-in concurrent metasearch aggregator (DuckDuckGo + Bing)
	builtin_items := search_builtin_aggregated(query, limit)
	if builtin_items.len == 0 {
		return ToolResult{
			content:  'No results found for "${query}".'
			is_error: false
		}
	}

	return ToolResult{
		content:  format_search_output(query, builtin_items, 'Aggregated (DuckDuckGo + Bing)')
		is_error: false
	}
}
