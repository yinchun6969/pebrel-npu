//! Native Pebrel AI chat transport.
//!
//! This module is UI-neutral. GPUI owns presentation/state, while this module
//! turns one enabled provider plus chat history into a blocking request. The
//! caller must run it off the UI thread.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::ai_providers::{AiProvider, ProviderKind};

const SYSTEM_PROMPT: &str = "You are Pebrel's built-in terminal assistant. Be concise, practical, and technically precise. When the user provides terminal output or code, explain the cause and give actionable next steps. Do not claim to have executed commands you did not execute.";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChatRole {
    User,
    Assistant,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: ChatRole,
    pub content: String,
}

impl ChatMessage {
    pub fn user(content: impl Into<String>) -> Self {
        Self { role: ChatRole::User, content: content.into() }
    }

    pub fn assistant(content: impl Into<String>) -> Self {
        Self { role: ChatRole::Assistant, content: content.into() }
    }

    fn openai_role(&self) -> &'static str {
        match self.role {
            ChatRole::User => "user",
            ChatRole::Assistant => "assistant",
        }
    }

    fn google_role(&self) -> &'static str {
        match self.role {
            ChatRole::User => "user",
            ChatRole::Assistant => "model",
        }
    }
}

fn api_key(provider: &AiProvider) -> Result<Zeroizing<String>, String> {
    if !provider.kind.requires_api_key() {
        return Ok(Zeroizing::new(String::new()));
    }
    let bytes = crate::ai_providers::load_api_key(&provider.id)
        .map_err(|error| format!("Could not read API key: {error}"))?
        .ok_or_else(|| format!("{} has no API key configured", provider.name))?;
    String::from_utf8(bytes)
        .map(Zeroizing::new)
        .map_err(|_| "Stored API key is not valid UTF-8".to_owned())
}

fn openai_messages(messages: &[ChatMessage]) -> Vec<serde_json::Value> {
    let mut payload = Vec::with_capacity(messages.len() + 1);
    payload.push(serde_json::json!({"role": "system", "content": SYSTEM_PROMPT}));
    payload.extend(messages.iter().map(|message| {
        serde_json::json!({
            "role": message.openai_role(),
            "content": message.content.as_str(),
        })
    }));
    payload
}

fn anthropic_messages(messages: &[ChatMessage]) -> Vec<serde_json::Value> {
    messages
        .iter()
        .map(|message| {
            serde_json::json!({
                "role": message.openai_role(),
                "content": message.content.as_str(),
            })
        })
        .collect()
}

fn google_contents(messages: &[ChatMessage]) -> Vec<serde_json::Value> {
    messages
        .iter()
        .map(|message| {
            serde_json::json!({
                "role": message.google_role(),
                "parts": [{"text": message.content}],
            })
        })
        .collect()
}

fn request_url(provider: &AiProvider) -> String {
    let base = provider.base_url.trim().trim_end_matches('/');
    if provider.full_url {
        return base.to_owned();
    }
    match provider.kind {
        ProviderKind::Anthropic => format!("{base}/messages"),
        ProviderKind::Google => {
            let model = provider.model.trim().trim_start_matches("models/");
            format!("{base}/models/{model}:generateContent")
        },
        ProviderKind::AzureOpenAi => {
            format!("{base}/{}/chat/completions?api-version=2024-10-21", provider.model.trim())
        },
        _ => format!("{base}/chat/completions"),
    }
}

fn request_body(provider: &AiProvider, messages: &[ChatMessage]) -> serde_json::Value {
    match provider.kind {
        ProviderKind::Anthropic => serde_json::json!({
            "model": provider.model.as_str(),
            "system": SYSTEM_PROMPT,
            "temperature": 0.2,
            "max_tokens": 1200,
            "messages": anthropic_messages(messages),
        }),
        ProviderKind::Google => serde_json::json!({
            "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
            "contents": google_contents(messages),
            "generationConfig": {"temperature": 0.2, "maxOutputTokens": 1200},
        }),
        ProviderKind::OpenVinoNpu => serde_json::json!({
            "model": provider.model.as_str(),
            "temperature": 0.2,
            "max_tokens": 1200,
            "stream": false,
            "chat_template_kwargs": {"enable_thinking": false},
            "messages": openai_messages(messages),
        }),
        _ => serde_json::json!({
            "model": provider.model.as_str(),
            "temperature": 0.2,
            "max_tokens": 1200,
            "stream": false,
            "messages": openai_messages(messages),
        }),
    }
}

fn extract_text(kind: ProviderKind, value: &serde_json::Value) -> Option<String> {
    match kind {
        ProviderKind::Anthropic => {
            value["content"][0]["text"].as_str().map(str::to_owned)
        },
        ProviderKind::Google => {
            value["candidates"][0]["content"]["parts"][0]["text"].as_str().map(str::to_owned)
        },
        _ => value["choices"][0]["message"]["content"].as_str().map(str::to_owned),
    }
}

pub fn send(provider: &AiProvider, messages: &[ChatMessage]) -> Result<String, String> {
    if !provider.enabled {
        return Err(format!("{} is disabled", provider.name));
    }
    if provider.base_url.trim().is_empty() {
        return Err(format!("{} has no API endpoint configured", provider.name));
    }
    if provider.model.trim().is_empty() {
        return Err(format!("{} has no model configured", provider.name));
    }
    if messages.is_empty() {
        return Err("Chat message is empty".to_owned());
    }

    let key = api_key(provider)?;
    let timeout = if provider.kind == ProviderKind::OpenVinoNpu {
        Duration::from_secs(180)
    } else {
        Duration::from_secs(90)
    };
    let config = ureq::config::Config::builder()
        .timeout_global(Some(timeout))
        .http_status_as_error(false)
        .build();
    let agent: ureq::Agent = config.new_agent();

    let url = request_url(provider);
    let body = request_body(provider, messages);
    let mut request = agent.post(&url);
    let bearer = Zeroizing::new(format!("Bearer {}", key.as_str()));
    request = match provider.kind {
        ProviderKind::Anthropic => request
            .header("x-api-key", key.as_str())
            .header("anthropic-version", "2023-06-01"),
        ProviderKind::Google => request.header("x-goog-api-key", key.as_str()),
        ProviderKind::AzureOpenAi => request.header("api-key", key.as_str()),
        _ if key.is_empty() => request,
        _ => request.header("Authorization", bearer.as_str()),
    };

    let mut response = request
        .send_json(&body)
        .map_err(|error| format!("Request failed: {error}"))?;
    let status = response.status().as_u16();
    let value: serde_json::Value = response
        .body_mut()
        .read_json()
        .map_err(|error| format!("Provider returned invalid JSON: {error}"))?;

    if !(200..=299).contains(&status) {
        let detail = value
            .pointer("/error/message")
            .and_then(serde_json::Value::as_str)
            .or_else(|| value.get("message").and_then(serde_json::Value::as_str))
            .unwrap_or("request rejected");
        return Err(format!("HTTP {status}: {detail}"));
    }

    extract_text(provider.kind, &value)
        .filter(|text| !text.trim().is_empty())
        .ok_or_else(|| "Provider response did not contain assistant text".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn openai_compatible_url_appends_chat_completions() {
        let mut provider =
            AiProvider::preset(ProviderKind::Custom, "custom-test");
        provider.base_url = "https://example.test/v1/".into();
        assert_eq!(
            request_url(&provider),
            "https://example.test/v1/chat/completions"
        );
    }

    #[test]
    fn openvino_body_disables_thinking() {
        let provider = AiProvider::preset(ProviderKind::OpenVinoNpu, "npu");
        let body = request_body(&provider, &[ChatMessage::user("hello")]);
        assert_eq!(
            body["chat_template_kwargs"]["enable_thinking"],
            serde_json::Value::Bool(false)
        );
    }

    #[test]
    fn assistant_history_keeps_role_order() {
        let messages = vec![
            ChatMessage::user("one"),
            ChatMessage::assistant("two"),
            ChatMessage::user("three"),
        ];
        let payload = openai_messages(&messages);
        assert_eq!(payload[1]["role"], "user");
        assert_eq!(payload[2]["role"], "assistant");
        assert_eq!(payload[3]["role"], "user");
    }
}
