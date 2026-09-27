# Native provider-backed AI chat

## Status

Accepted for the `feature/intel-npu-v1` experiment.

## Context

Pebrel now has a provider registry with an Intel NPU/OpenVINO preset and user-defined
OpenAI-compatible providers. The Settings page can validate credentials/endpoints and manage
the local OVMS runtime, but users still need an external CLI such as Codex to have an actual
conversation. That leaves the provider registry as configuration without a first-party product
surface.

The GPUI product shell already has a standard modal system and terminal/document selection
context menus. A first native chat slice should reuse those primitives instead of adding a new
terminal process, pseudo-PTY protocol, or another persisted tab type before the request path is
validated.

## Decision

Add a GPUI-native **Pebrel AI Chat** modal backed directly by enabled entries in
`ai_providers::ProviderStore`.

The first slice:

- opens from **Ctrl+Shift+A** and the command palette;
- lists only enabled providers and defaults to the active provider when possible;
- sends requests on the GPUI background executor;
- supports OpenAI-compatible chat completions, Intel NPU/OVMS, Anthropic, Google, and Azure
  request shapes using the existing provider metadata/credential store;
- keeps multi-turn history in memory for the lifetime of the modal;
- exposes terminal/document selections through **Analyze with Pebrel AI...**, pre-filling the
  selected text as context;
- keeps API keys in the OS credential store and never copies plaintext credentials into chat UI
  state;
- configures the validated OpenVINO Qwen3 provider with
  `chat_template_kwargs.enable_thinking=false` for predictable content responses.

The transport lives in `native_ai_chat.rs` and is UI-neutral. The workspace modal owns only
presentation and ephemeral conversation state.

## Deliberate limits of this slice

- Responses are non-streaming. This establishes correctness across local NPU and third-party
  providers before adding chunk/event parsing.
- Chat history is not persisted across Pebrel restarts.
- There is no tool execution or automatic shell command execution. AI output is advisory text.
- The native chat does not replace existing Claude/Codex Agent panes or their Send to Chat
  workflow; both paths remain distinct in the selection menu.

## Safety / privacy boundary

- Only enabled providers can be selected.
- Terminal/document text is sent only after an explicit user action.
- API keys are loaded immediately before the background request and held in a zeroizing buffer.
- The system prompt explicitly forbids claiming execution that did not occur.
- No assistant response is automatically executed in the terminal.

## Validation

Before the draft PR is ready:

1. Release build succeeds with `--features gpui-shell`.
2. Ctrl+Shift+A opens the modal.
3. Intel NPU provider returns a real Qwen3 answer through
   `http://127.0.0.1:8000/v3/chat/completions`.
4. A configured OpenAI-compatible provider returns a real answer.
5. Multi-turn history is included in a second request.
6. Selecting terminal text -> **Analyze with Pebrel AI...** opens the same modal with the text
   pre-filled.
7. Provider/API failures remain inside the modal as readable errors and do not crash GPUI.

## Revisit when

- streaming response UX is added;
- chat becomes a persistent workspace tab or side panel;
- conversation persistence or tool execution is proposed.
