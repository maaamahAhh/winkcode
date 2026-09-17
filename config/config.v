module config

import os
import json2

pub struct CompatConfig {
pub:
	thinking_format string @[json: "thinkingFormat"] // "", "openrouter", "zai"
}

pub struct ProviderConfig {
pub:
	api      string            @[json: "api"] // "anthropic" or "openai"
	base_url string            @[json: "baseUrl"]
	headers  map[string]string @[json: "headers"]
	compat   CompatConfig      @[json: "compat"]
	api_key  string            @[json: "apiKey"]
}

pub struct ModelConfig {
pub:
	provider       string @[json: "provider"]
	max_tokens     int    @[json: "maxTokens"]
	context_window int    @[json: "contextWindow"]
	reasoning      bool   @[json: "reasoning"]
	effort         string @[json: "effort"]
}

// AppConfig maps to ~/.winkcode/config.json
pub struct AppConfig {
pub:
	default_model string                    @[json: "defaultModel"]
	effort        string                    @[json: "effort"]
	providers     map[string]ProviderConfig @[json: "providers"]
	models        map[string]ModelConfig    @[json: "models"]
}

// ResolvedConfig contains everything the LLM client needs
pub struct ResolvedConfig {
pub:
	api_key         string
	api_url         string
	model           string
	max_tokens      int
	context_window  int
	api_format      string // "anthropic" or "openai"
	effort          string // "low", "medium", "high", "max"
	thinking_format string // "", "openrouter", "zai"
	reasoning       bool   // whether the model supports reasoning/extended thinking
}

// Config is the main configuration object
pub struct Config {
pub mut:
	current_model string
	effort        string
	providers     map[string]ProviderConfig
	models        map[string]ModelConfig
	auth          map[string]string
	// Session state
	current_session_id   string
	current_session_path string
}

fn builtin_providers() map[string]ProviderConfig {
	return {
		'anthropic': ProviderConfig{
			api:      'anthropic'
			base_url: 'https://api.anthropic.com'
		}
		'openai':    ProviderConfig{
			api:      'openai'
			base_url: 'https://api.openai.com/v1'
		}
	}
}

fn builtin_models() map[string]ModelConfig {
	return {
		'claude-opus-5':     ModelConfig{
			provider:       'anthropic'
			max_tokens:     64000
			context_window: 1000000
			reasoning:      true
		}
		'claude-sonnet-5':   ModelConfig{
			provider:       'anthropic'
			max_tokens:     128000
			context_window: 1000000
			reasoning:      true
		}
		'claude-opus-4-8':   ModelConfig{
			provider:       'anthropic'
			max_tokens:     64000
			context_window: 1000000
			reasoning:      true
		}
		'claude-opus-4-7':   ModelConfig{
			provider:       'anthropic'
			max_tokens:     32000
			context_window: 1000000
			reasoning:      true
		}
		'claude-opus-4-6':   ModelConfig{
			provider:       'anthropic'
			max_tokens:     32000
			context_window: 1000000
			reasoning:      true
		}
		'claude-sonnet-4-6': ModelConfig{
			provider:       'anthropic'
			max_tokens:     32000
			context_window: 1000000
			reasoning:      true
		}
		'claude-haiku-4-5':  ModelConfig{
			provider:       'anthropic'
			max_tokens:     64000
			context_window: 200000
			reasoning:      true
		}
		'gpt-6-astra':       ModelConfig{
			provider:       'openai'
			max_tokens:     128000
			context_window: 1050000
			reasoning:      true
		}
		'gpt-5.6-luna':      ModelConfig{
			provider:       'openai'
			max_tokens:     128000
			context_window: 1050000
			reasoning:      true
		}
		'gpt-5.6-terra':     ModelConfig{
			provider:       'openai'
			max_tokens:     128000
			context_window: 1050000
			reasoning:      true
		}
		'gpt-5.6-sol':       ModelConfig{
			provider:       'openai'
			max_tokens:     128000
			context_window: 1050000
			reasoning:      true
		}
		'gpt-5.5':           ModelConfig{
			provider:       'openai'
			max_tokens:     128000
			context_window: 1000000
			reasoning:      true
		}
		'gpt-5.4':           ModelConfig{
			provider:       'openai'
			max_tokens:     128000
			context_window: 1000000
			reasoning:      true
		}
		'gpt-5.3':           ModelConfig{
			provider:       'openai'
			max_tokens:     128000
			context_window: 1000000
			reasoning:      true
		}
	}
}

fn config_dir() string {
	return os.join_path(os.home_dir(), '.winkcode')
}

fn config_path() string {
	return os.join_path(config_dir(), 'config.json')
}

fn auth_path() string {
	return os.join_path(config_dir(), 'auth.json')
}

pub fn load() Config {
	mut providers := builtin_providers()
	mut models := builtin_models()
	mut auth := load_auth()
	mut default_model := 'claude-opus-4-8'
	mut effort := 'medium'

	app_cfg := load_config_file()
	for k, v in app_cfg.providers {
		providers[k] = v
		if v.api_key.len > 0 && k !in auth {
			resolved_key := resolve_api_key_value(v.api_key)
			if resolved_key.len > 0 {
				auth[k] = resolved_key
			}
		}
	}
	for k, v in app_cfg.models {
		models[k] = v
	}
	if app_cfg.default_model.len > 0 {
		default_model = app_cfg.default_model
	}
	if app_cfg.effort.len > 0 {
		effort = app_cfg.effort
	} else if default_model in models && models[default_model].effort.len > 0 {
		effort = models[default_model].effort
	}

	default_model = apply_env_overrides(mut providers, default_model)

	return Config{
		current_model: default_model
		effort:        effort
		providers:     providers
		models:        models
		auth:          auth
	}
}

fn resolve_api_key_value(val string) string {
	trimmed := val.trim_space()
	if trimmed.starts_with('$') && trimmed.len > 1 {
		return os.getenv(trimmed[1..])
	}
	return trimmed
}

fn load_auth() map[string]string {
	mut auth := map[string]string{}
	if os.exists(auth_path()) {
		data := os.read_file(auth_path()) or { '' }
		if data.len > 0 {
			loaded := json2.decode[map[string]string](data) or {
				map[string]string{}
			}
			for k, v in loaded {
				resolved_v := resolve_api_key_value(v)
				if resolved_v.len > 0 {
					auth[k] = resolved_v
				}
			}
		}
	}

	// Fallback: API keys from environment variables
	env_fallbacks := [['anthropic', 'ANTHROPIC_API_KEY'], ['openai', 'OPENAI_API_KEY']]
	for pair in env_fallbacks {
		if pair[0] !in auth {
			val := os.getenv(pair[1])
			if val.len > 0 {
				auth[pair[0]] = val
			}
		}
	}
	return auth
}

fn load_config_file() AppConfig {
	if !os.exists(config_path()) {
		return AppConfig{}
	}
	data := os.read_file(config_path()) or { '' }
	if data.len == 0 {
		return AppConfig{}
	}
	return json2.decode[AppConfig](data) or { AppConfig{} }
}

fn apply_env_overrides(mut providers map[string]ProviderConfig, default_model string) string {
	mut model := default_model

	anthropic_url := os.getenv('ANTHROPIC_API_URL')
	if anthropic_url.len > 0 && 'anthropic' in providers {
		old := providers['anthropic']
		providers['anthropic'] = ProviderConfig{
			api:      old.api
			base_url: anthropic_url
			headers:  old.headers
			compat:   old.compat
		}
	}

	model_env := os.getenv('WINK_MODEL')
	if model_env.len > 0 {
		model = model_env
	}
	return model
}

pub fn (c &Config) resolve() !ResolvedConfig {
	return c.resolve_model(c.current_model)
}

pub fn (c &Config) resolve_model(model_name string) !ResolvedConfig {
	model_cfg := c.models[model_name] or { return error('unknown model: ${model_name}') }
	provider_cfg := c.providers[model_cfg.provider] or {
		return error('unknown provider: ${model_cfg.provider}')
	}
	api_key := c.auth[model_cfg.provider] or {
		return error('no API key for provider: ${model_cfg.provider}')
	}

	// Build full API URL from base_url + path based on api format
	mut api_url := provider_cfg.base_url
	if api_url.ends_with('/') {
		api_url = api_url[..api_url.len - 1]
	}
	match provider_cfg.api {
		'anthropic' {
			if api_url.ends_with('/v1') {
				api_url = api_url[..api_url.len - 3]
			}
			api_url += '/v1/messages'
		}
		'openai' {
			if !api_url.ends_with('/v1') {
				api_url += '/v1'
			}
			api_url += '/chat/completions'
		}
		else {}
	}

	context_win := if model_cfg.context_window > 0 { model_cfg.context_window } else { 256_000 }
	effort_val := if model_cfg.effort.len > 0 {
		model_cfg.effort
	} else if c.effort.len > 0 {
		c.effort
	} else {
		'medium'
	}

	return ResolvedConfig{
		api_key:         api_key
		api_url:         api_url
		model:           model_name
		max_tokens:      model_cfg.max_tokens
		context_window:  context_win
		api_format:      provider_cfg.api
		effort:          effort_val
		thinking_format: provider_cfg.compat.thinking_format
		reasoning:       model_cfg.reasoning
	}
}

pub fn (mut c Config) set_model(name string) ! {
	model_cfg := c.models[name] or { return error('unknown model: ${name}') }
	c.current_model = name
	if model_cfg.effort.len > 0 {
		c.effort = model_cfg.effort
	}
}

pub fn (mut c Config) set_effort(level string) ! {
	if level !in ['low', 'medium', 'high', 'max'] {
		return error('invalid effort: ${level} (valid: low, medium, high, max)')
	}
	c.effort = level
}

pub fn (c &Config) get_model_names() []string {
	mut names := []string{}
	for k, _ in c.models {
		names << k
	}
	names.sort()
	return names
}

pub fn (c &Config) get_model_provider(name string) string {
	model := c.models[name] or { return '' }
	return model.provider
}

pub fn (c &Config) get_current_model() string {
	return c.current_model
}

pub fn (c &Config) get_effort() string {
	return c.effort
}
