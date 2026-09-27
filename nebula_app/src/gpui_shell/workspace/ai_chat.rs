//! Native AI chat dialog for the GPUI product shell.
//!
//! This is intentionally a workspace-level modal instead of another terminal
//! process. It uses enabled providers from Settings, keeps conversation history
//! in memory for the lifetime of the dialog, and runs blocking provider calls on
//! the background executor.

use std::sync::Arc;

use gpui::{
    AnyElement, App, AppContext as _, Context, Entity, Focusable as _, IntoElement,
    ParentElement as _, SharedString, Styled as _, Window, div, px, relative,
};
use gpui_component::select::SelectItem;

use crate::gpui_shell::prelude::*;
use crate::native_ai_chat::{ChatMessage, ChatRole};

use super::{NebulaWorkspace, workspace_ui_language};

const AI_CHAT_DIALOG_HEIGHT: f32 = 720.0;
const AI_CHAT_HISTORY_HEIGHT: f32 = 390.0;
const AI_CHAT_INPUT_HEIGHT: f32 = 120.0;

#[derive(Clone)]
struct AiChatProviderItem {
    id: String,
    title: SharedString,
    model: SharedString,
    search: String,
}

impl SelectItem for AiChatProviderItem {
    type Value = String;

    fn title(&self) -> SharedString {
        self.title.clone()
    }

    fn display_title(&self) -> Option<AnyElement> {
        Some(
            h_flex()
                .min_w_0()
                .gap_2()
                .child(Icon::new(IconName::Bot).xsmall())
                .child(div().min_w_0().flex_1().truncate().child(self.title.clone()))
                .child(
                    div()
                        .max_w(px(180.0))
                        .truncate()
                        .text_xs()
                        .text_color(gpui::hsla(0.0, 0.0, 0.55, 1.0))
                        .child(self.model.clone()),
                )
                .into_any_element(),
        )
    }

    fn value(&self) -> &Self::Value {
        &self.id
    }

    fn matches(&self, query: &str) -> bool {
        self.search.contains(&query.to_lowercase())
    }
}

#[derive(Default)]
struct NativeAiChatState {
    messages: Vec<ChatMessage>,
    loading: bool,
    error: Option<String>,
    request_seq: u64,
}

impl NativeAiChatState {
    fn clear(&mut self) {
        self.messages.clear();
        self.error = None;
        self.loading = false;
        self.request_seq = self.request_seq.wrapping_add(1);
    }
}

fn provider_items() -> (Vec<AiChatProviderItem>, String) {
    let store = crate::ai_providers::load();
    let active_id = store.active_id.clone();
    let items = store
        .providers
        .into_iter()
        .filter(|provider| provider.enabled)
        .map(|provider| AiChatProviderItem {
            search: format!(
                "{} {} {}",
                provider.name, provider.model, provider.base_url
            )
            .to_lowercase(),
            id: provider.id,
            title: provider.name.into(),
            model: provider.model.into(),
        })
        .collect();
    (items, active_id)
}

fn chat_turn(message: &ChatMessage, cx: &App) -> AnyElement {
    let language = crate::gpui_shell::config::ui_language(cx);
    let (label, bg) = match message.role {
        ChatRole::User => (
            language.pick("你", "You"),
            cx.theme().primary.opacity(0.10),
        ),
        ChatRole::Assistant => (
            language.pick("AI", "AI"),
            cx.theme().group_box,
        ),
    };
    v_flex()
        .w_full()
        .gap_1()
        .rounded(px(crate::display::ui::tokens::radius::CONTROL))
        .bg(bg)
        .px_3()
        .py_2()
        .child(
            div()
                .text_xs()
                .font_semibold()
                .text_color(cx.theme().muted_foreground)
                .child(label),
        )
        .child(
            div()
                .text_sm()
                .line_height(relative(1.45))
                .text_color(cx.theme().foreground)
                .child(message.content.clone()),
        )
        .into_any_element()
}

impl NebulaWorkspace {
    pub(super) fn open_native_ai_chat_dialog(
        &mut self,
        prefill: Option<Arc<str>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let language = workspace_ui_language();
        let (providers, active_id) = provider_items();
        if providers.is_empty() {
            crate::gpui_shell::toast::toast(
                window,
                cx,
                crate::display::ToastKind::Warning,
                language.pick(
                    "没有已启用的 AI 供应商，请先到设置 → AI 供应商启用一个。",
                    "No AI provider is enabled. Enable one in Settings → AI Providers first.",
                ),
            );
            return;
        }

        let selected = providers
            .iter()
            .find(|provider| provider.id == active_id)
            .map(|provider| provider.id.clone())
            .or_else(|| providers.first().map(|provider| provider.id.clone()));
        let provider_count = providers.len();
        let provider_select =
            cx.new(|cx| SelectState::new(providers, selected, window, cx).searchable(provider_count > 5));
        let input = cx.new(|cx| InputState::new(window, cx).multi_line(true).soft_wrap(true));
        if let Some(prefill) = prefill {
            let prompt = format!(
                "{}\n\n{}",
                language.pick(
                    "请分析下面的终端/文本内容，说明原因并给出可执行的解决步骤：",
                    "Analyze the terminal/text content below, explain the cause, and give actionable steps:",
                ),
                prefill
            );
            input.update(cx, |input, cx| input.set_value(prompt, window, cx));
        }
        let state = cx.new(|_| NativeAiChatState::default());
        let workspace = cx.entity().downgrade();

        let dialog_provider_select = provider_select.clone();
        let dialog_input = input.clone();
        let dialog_state = state.clone();
        window.open_dialog(cx, move |dialog, window, cx| {
            let snapshot = dialog_state.read(cx);
            let messages = snapshot.messages.clone();
            let loading = snapshot.loading;
            let error = snapshot.error.clone();
            drop(snapshot);

            let history = if messages.is_empty() {
                v_flex()
                    .w_full()
                    .h_full()
                    .items_center()
                    .justify_center()
                    .child(
                        div()
                            .text_sm()
                            .text_color(cx.theme().muted_foreground)
                            .child(language.pick(
                                "选择供应商后直接提问。对话只保存在当前窗口内。",
                                "Choose a provider and ask a question. This conversation is kept only in the current window.",
                            )),
                    )
                    .into_any_element()
            } else {
                v_flex()
                    .w_full()
                    .gap_2()
                    .children(messages.iter().map(|message| chat_turn(message, cx)))
                    .when(loading, |history| {
                        history.child(
                            div()
                                .text_sm()
                                .text_color(cx.theme().muted_foreground)
                                .child(language.pick("正在生成…", "Generating…")),
                        )
                    })
                    .into_any_element()
            };

            let body = v_flex()
                .w_full()
                .gap_3()
                .child(
                    v_flex()
                        .w_full()
                        .gap_1()
                        .child(
                            div()
                                .text_sm()
                                .font_semibold()
                                .child(language.pick("AI 供应商", "AI Provider")),
                        )
                        .child(
                            div()
                                .w_full()
                                .h_8()
                                .child(
                                    Select::new(&dialog_provider_select)
                                        .placeholder(language.pick("选择供应商", "Choose provider"))
                                        .search_placeholder(
                                            language.pick("搜索供应商…", "Search providers…"),
                                        ),
                                ),
                        ),
                )
                .child(
                    div()
                        .id("native-ai-chat-history")
                        .w_full()
                        .h(px(AI_CHAT_HISTORY_HEIGHT))
                        .overflow_y_scroll()
                        .rounded(px(crate::display::ui::tokens::radius::CONTROL))
                        .border_1()
                        .border_color(cx.theme().border)
                        .bg(cx.theme().muted)
                        .p_2()
                        .child(history),
                )
                .children(error.map(|error| {
                    div()
                        .text_sm()
                        .text_color(cx.theme().danger)
                        .child(error)
                }))
                .child(
                    v_flex()
                        .w_full()
                        .gap_1()
                        .child(
                            div()
                                .text_sm()
                                .font_semibold()
                                .child(language.pick("消息", "Message")),
                        )
                        .child(
                            div()
                                .w_full()
                                .h(px(AI_CHAT_INPUT_HEIGHT))
                                .child(Input::new(&dialog_input)),
                        ),
                );

            let clear_state = dialog_state.clone();
            let clear_input = dialog_input.clone();
            let footer = DialogFooter::new()
                .child(
                    Button::new("native-ai-chat-clear")
                        .label(language.pick("新对话", "New chat"))
                        .ghost()
                        .disabled(loading)
                        .on_click(move |_, window, cx| {
                            clear_state.update(cx, |state, _| state.clear());
                            clear_input.update(cx, |input, cx| {
                                input.set_value(String::new(), window, cx)
                            });
                        }),
                )
                .child(div().flex_1())
                .child(
                    DialogClose::new().child(
                        Button::new("native-ai-chat-close")
                            .label(language.pick("关闭", "Close")),
                    ),
                )
                .child(
                    DialogAction::new().child(
                        Button::new("native-ai-chat-send")
                            .label(if loading {
                                language.pick("生成中…", "Generating…")
                            } else {
                                language.pick("发送", "Send")
                            })
                            .primary()
                            .disabled(
                                loading
                                    || dialog_provider_select
                                        .read(cx)
                                        .selected_value()
                                        .is_none(),
                            ),
                    ),
                );

            let send_workspace = workspace.clone();
            let send_state = dialog_state.clone();
            let send_input = dialog_input.clone();
            let send_provider = dialog_provider_select.clone();
            center_modal_dialog(dialog, window, AI_CHAT_DIALOG_HEIGHT)
                .close_button(true)
                .overlay_closable(false)
                .title(
                    div()
                        .text_lg()
                        .font_semibold()
                        .child(language.pick("Pebrel AI Chat", "Pebrel AI Chat")),
                )
                .footer(footer)
                .child(body)
                .on_ok(move |_, window, cx| {
                    if send_state.read(cx).loading {
                        return false;
                    }
                    let Some(provider_id) = send_provider.read(cx).selected_value().cloned() else {
                        return false;
                    };
                    let prompt = send_input.read(cx).value().to_string();
                    if prompt.trim().is_empty() {
                        crate::gpui_shell::toast::toast(
                            window,
                            cx,
                            crate::display::ToastKind::Warning,
                            language.pick("请输入消息", "Enter a message"),
                        );
                        return false;
                    }
                    send_input.update(cx, |input, cx| {
                        input.set_value(String::new(), window, cx)
                    });
                    if let Some(workspace) = send_workspace.upgrade() {
                        workspace.update(cx, |workspace, cx| {
                            workspace.submit_native_ai_chat(
                                send_state.clone(),
                                provider_id,
                                prompt,
                                cx,
                            );
                        });
                    }
                    false
                })
        });

        input.focus_handle(cx).focus(window, cx);
    }

    fn submit_native_ai_chat(
        &mut self,
        state: Entity<NativeAiChatState>,
        provider_id: String,
        prompt: String,
        cx: &mut Context<Self>,
    ) {
        let store = crate::ai_providers::load();
        let Some(provider) = store
            .providers
            .into_iter()
            .find(|provider| provider.id == provider_id && provider.enabled)
        else {
            state.update(cx, |state, cx| {
                state.error = Some("Selected AI provider is no longer enabled.".to_owned());
                state.loading = false;
                cx.notify();
            });
            return;
        };

        let (sequence, messages) = state.update(cx, |state, cx| {
            state.request_seq = state.request_seq.wrapping_add(1);
            let sequence = state.request_seq;
            state.messages.push(ChatMessage::user(prompt));
            state.loading = true;
            state.error = None;
            let messages = state.messages.clone();
            cx.notify();
            (sequence, messages)
        });

        let task = cx
            .background_executor()
            .spawn(async move { crate::native_ai_chat::send(&provider, &messages) });
        cx.spawn(async move |_this, cx| {
            let result = task.await;
            let _ = state.update(cx, |state, cx| {
                if state.request_seq != sequence {
                    return;
                }
                state.loading = false;
                match result {
                    Ok(answer) => state.messages.push(ChatMessage::assistant(answer)),
                    Err(error) => state.error = Some(error),
                }
                cx.notify();
            });
        })
        .detach();
    }
}
