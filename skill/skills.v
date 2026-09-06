module skill

import os

// Skill represents a single skill discovered from ~/.winkcode/skills/ or project skills/.
pub struct Skill {
pub:
	name        string
	description string
	path        string
}

// load_skills scans global and project skill directories for SKILL.md files.
pub fn load_skills(cwd string) []Skill {
	mut skills := []Skill{}

	// Global skills
	home := os.home_dir()
	if home.len > 0 {
		global_skills_dir := os.join_path(home, '.winkcode', 'skills')
		skills << scan_skills_dir(global_skills_dir)
	}

	// Project skills (relative to cwd)
	project_skills_dir := os.join_path(cwd, 'skills')
	skills << scan_skills_dir(project_skills_dir)

	return skills
}

// format_skills_for_prompt builds the XML skills section for the system prompt.
pub fn format_skills_for_prompt(skills []Skill) string {
	if skills.len == 0 {
		return ''
	}

	mut parts := []string{}
	parts << "\n\nSkills: read a skill's SKILL.md when the task matches its description."
	parts << '\n<skills>'
	for skill in skills {
		parts << '  <skill name="${skill.name}" description="${skill.description}" path="${skill.path}"/>'
	}
	parts << '</skills>'
	return parts.join('\n')
}

fn scan_skills_dir(dir string) []Skill {
	mut skills := []Skill{}
	if !os.exists(dir) || !os.is_dir(dir) {
		return skills
	}

	entries := os.ls(dir) or { return skills }
	for entry in entries {
		entry_path := os.join_path(dir, entry)
		if !os.is_dir(entry_path) {
			continue
		}
		skill_md := os.join_path(entry_path, 'SKILL.md')
		if os.exists(skill_md) {
			description := extract_description(skill_md)
			skills << Skill{
				name:        entry
				description: description
				path:        skill_md
			}
		}
	}
	return skills
}

fn extract_description(path string) string {
	content := os.read_file(path) or { return '' }
	lines := content.split('\n')
	mut in_frontmatter := false
	mut body_first_line := ''

	for i, line in lines {
		trimmed := line.trim_space()
		if i == 0 && trimmed.starts_with('---') {
			in_frontmatter = true
			continue
		}
		if in_frontmatter {
			if trimmed.starts_with('---') {
				in_frontmatter = false
				continue
			}
			if trimmed.starts_with('description:') {
				mut desc := trimmed['description:'.len..].trim_space()
				if (desc.starts_with('"') && desc.ends_with('"'))
					|| (desc.starts_with("'") && desc.ends_with("'")) {
					if desc.len >= 2 {
						desc = desc[1..desc.len - 1].trim_space()
					}
				}
				if desc.len > 0 {
					return desc
				}
			}
			continue
		}

		if trimmed.len == 0 || trimmed.starts_with('#') {
			continue
		}
		if body_first_line.len == 0 {
			body_first_line = trimmed
			break
		}
	}

	if body_first_line.len > 0 {
		return body_first_line
	}
	return 'Skill'
}
