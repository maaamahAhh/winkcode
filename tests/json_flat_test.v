module tests

import utils


fn test_parse_flat_json_simple() {
	res := utils.parse_flat_json('{"path": "hello.txt"}') or {
		assert false, 'failed to parse simple object: ${err}'
		return
	}
	assert res['path'] == 'hello.txt'
}

fn test_parse_flat_json_multiple_types() {
	input := '{"command": "dir /b", "timeout": 30, "read_only": true, "ignore_case": false}'
	res := utils.parse_flat_json(input) or {
		assert false, 'failed to parse multiple types: ${err}'
		return
	}
	assert res['command'] == 'dir /b'
	assert res['timeout'] == '30'
	assert res['read_only'] == 'true'
	assert res['ignore_case'] == 'false'
}

fn test_parse_flat_json_windows_path() {
	input := '{"path": "E:\\\\test\\\\hyper.html"}'
	res := utils.parse_flat_json(input) or {
		assert false, 'failed to parse windows path: ${err}'
		return
	}
	assert res['path'] == 'E:\\test\\hyper.html'
}

fn test_parse_flat_json_curly_braces_in_value() {
	input := '{"prompt": "write {cool} code", "read_only": false}'
	res := utils.parse_flat_json(input) or {
		assert false, 'failed to parse braces in value: ${err}'
		return
	}
	assert res['prompt'] == 'write {cool} code'
	assert res['read_only'] == 'false'
}

fn test_parse_flat_json_nested_array() {
	input := '{"name": "test", "args": ["a", "b"]}'
	res := utils.parse_flat_json(input) or {
		assert false, 'failed to parse nested array: ${err}'
		return
	}
	assert res['name'] == 'test'
	assert res['args'] == '["a", "b"]'
}

fn test_parse_flat_json_empty() {
	res1 := utils.parse_flat_json('{}') or { map[string]string{} }
	assert res1.len == 0
	res2 := utils.parse_flat_json('') or { map[string]string{} }
	assert res2.len == 0
}

fn test_parse_flat_json_without_braces() {
	input := '"path": "hello.txt", "timeout": 15'
	res := utils.parse_flat_json(input) or {
		assert false, 'failed to parse unbraced: ${err}'
		return
	}
	assert res['path'] == 'hello.txt'
	assert res['timeout'] == '15'
}
