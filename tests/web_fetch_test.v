module tests

import tools

fn test_find_tag_end() {
	assert tools.find_tag_end('<div>hello</div>', 0) == 4

	html_single := "<a href='https://example.com/?tag=>foo'>click</a>"
	end_single := tools.find_tag_end(html_single, 0)
	assert html_single[end_single..end_single + 6] == '>click'

	html_hf := '<div class="btn" data-props="{&quot;token&quot;:&quot;sentence|>&quot;}">content</div>'
	end_hf := tools.find_tag_end(html_hf, 0)
	assert html_hf[end_hf..end_hf + 8] == '>content'
}

fn test_strip_html_block() {
	html := '<html><SCRIPT type="text/javascript">var x = 1 > 0;</SCRIPT><p>Hello</p></html>'
	cleaned := tools.strip_html_block(html, 'script')
	assert !cleaned.to_lower().contains('var x')
	assert cleaned.contains('<p>Hello</p>')

	html_head := '<html><head><title>Test</title></head><header><h1>Header Title</h1></header></html>'
	cleaned_head := tools.strip_html_block(html_head, 'head')
	assert !cleaned_head.contains('<title>')
	assert cleaned_head.contains('<header>')
}

fn test_clean_html_to_markdown_hydration_props() {
	html := '<!DOCTYPE html><html><head><title>Model Page</title></head><body>' +
		'<div class="SVELTE_HYDRATER" data-props="{&quot;tokens&quot;:[&quot;<|sentence|>&quot;]' +
		',&quot;availableInferenceProviders&quot;:[&quot;hf-inference&quot;],&quot;lstrip&quot;:false}"></div>' +
		'<h1>DeepSeek V4</h1><p>This is a great model.</p>' +
		'<a href="https://example.com">Visit Link</a></body></html>'

	md := tools.clean_html_to_markdown(html, 'https://huggingface.co/test')

	assert md.contains('# Model Page')
	assert md.contains('DeepSeek V4')
	assert md.contains('This is a great model.')
	assert md.contains('[Visit Link](https://example.com)')
	assert !md.contains('availableInferenceProviders')
	assert !md.contains('lstrip')
}

fn test_convert_github_url_to_raw() {
	url := 'https://github.com/vlang/v/blob/master/vlib/net/http/http.v'
	raw := tools.convert_github_url_to_raw(url)
	assert raw == 'https://raw.githubusercontent.com/vlang/v/master/vlib/net/http/http.v'

	assert tools.convert_github_url_to_raw('https://github.com/vlang/v') == 'https://github.com/vlang/v'
}

fn test_is_local_or_private_url() {
	assert tools.is_local_or_private_url('http://localhost:3000/api') == true
	assert tools.is_local_or_private_url('http://127.0.0.1:8080') == true
	assert tools.is_local_or_private_url('http://192.168.1.1/admin') == true
	assert tools.is_local_or_private_url('http://10.0.0.5') == true
	assert tools.is_local_or_private_url('https://huggingface.co/models') == false
}
