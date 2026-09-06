module tests

import tools

fn test_glob_star_root() {
	assert tools.glob_match('**/*.html', 'wink-code-landing.html')
	assert tools.glob_match('**/*.html', 'sub/page.html')
	assert tools.glob_match('**/*.html', 'a/b/c/deep.html')
}

fn test_glob_star_subfolder() {
	assert tools.glob_match('src/**/*.v', 'src/agent/subagent.v')
	assert tools.glob_match('src/**/*.v', 'src/main.v')
	assert !tools.glob_match('src/*.v', 'src/agent/subagent.v')
	assert tools.glob_match('src/*.v', 'src/main.v')
}

fn test_matches_glob_scenarios() {
	assert tools.matches_glob('E:/test/wink-code-landing.html', '**/*.html', 'E:/test')
	assert tools.matches_glob('E:/test/wink-code-landing.html', 'wink-code-landing.html', 'E:/test')
	assert tools.matches_glob('E:\\test\\wink-code-landing.html', 'E:\\test\\wink-code-landing.html', 'E:\\test')
	assert tools.matches_glob('E:\\test\\sub\\button.html', '**/*.html', 'E:\\test')
	assert tools.matches_glob('E:/test/sub/button.html', '*.html', 'E:/test')
}

fn test_make_relative_to() {
	assert tools.make_relative_to('E:\\test\\wink-code-landing.html', 'E:\\test') == 'wink-code-landing.html'
	assert tools.make_relative_to('E:/test/sub/button.html', 'E:/test') == 'sub/button.html'
	assert tools.make_relative_to('E:\\test\\sub\\button.html', 'e:\\test') == 'sub/button.html'
}
