# Intel NPU support (experimental)

This fork adds a local **Intel NPU (OpenVINO)** provider for Windows AI PCs.

## Target hardware

The first validation target is:

- Intel Core Ultra 7 155H (Meteor Lake)
- Intel AI Boost NPU
- Intel Arc integrated graphics
- Windows 11
- 32 GB RAM

The implementation uses OpenVINO Model Server (OVMS) as a loopback-only OpenAI-compatible
inference service. Pebrel remains the terminal/UI process; the NPU is used for local model
inference rather than terminal rendering.

## Architecture

```text
Pebrel
  |
  | OpenAI-compatible HTTP (127.0.0.1 only)
  v
OpenVINO Model Server
  |
  +--> Intel NPU (primary)
```

The built-in provider defaults to:

- Provider: `Intel NPU (OpenVINO)`
- Base URL: `http://127.0.0.1:8000/v3`
- Model: `OpenVINO/Qwen3-8B-int4-cw-ov`
- API key: not required

The provider connectivity check uses the OVMS `/v1/config` readiness endpoint.

## One-command setup on Windows

Open **PowerShell** in the repository directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\pebrel-npu.ps1 setup
```

The setup action:

1. Detects Intel AI Boost / NPU in Windows.
2. Downloads the latest official Windows OVMS `python_off` package.
3. Verifies the published SHA-256 checksum when available.
4. Pulls the NPU-ready OpenVINO Qwen3 INT4 model.
5. Builds an OVMS config targeting `NPU`.
6. Starts OVMS on 127.0.0.1:8000 only.
7. Runs a small OpenAI-compatible chat request.

Runtime files are stored under:

```text
%LOCALAPPDATA%\PebrelNPU
```

## Useful commands

```powershell
# Hardware/runtime diagnosis
.\scripts\pebrel-npu.ps1 doctor

# Only install OVMS
.\scripts\pebrel-npu.ps1 install

# Pull/prepare the default NPU model
.\scripts\pebrel-npu.ps1 model

# Start/stop local model server
.\scripts\pebrel-npu.ps1 start
.\scripts\pebrel-npu.ps1 stop

# Create verified desktop shortcuts:
# "Start Pebrel NPU" starts OVMS if needed and then opens Pebrel.
# "Stop Pebrel NPU" stops the managed OVMS process tree.
.\scripts\pebrel-npu.ps1 shortcut -PebrelExe ".\target\release\pebrel.exe"

# Send a test generation
.\scripts\pebrel-npu.ps1 test
```

To try a different NPU-compatible model:

```powershell
.\scripts\pebrel-npu.ps1 model -Model "OpenVINO/Qwen3-8B-int4-cw-ov"
```

## Configure Pebrel

Build and launch this branch, then open:

```text
Settings -> AI Providers -> Intel NPU (OpenVINO)
```

The preset should already contain the local endpoint and model name. No API key is required.

When this provider is selected, the Settings page also shows **Intel NPU runtime** controls:
**Refresh**, **Start NPU**, and **Stop NPU**. Runtime probing and process operations run off
the UI thread. Pebrel only stops an OVMS process that has a managed PID; an externally
started OVMS instance is shown as external/unmanaged and is not force-killed.

Pebrel also exposes a native **Pebrel AI Chat** surface. Press **Ctrl+Shift+A** (or
open the command palette and choose **Pebrel AI Chat…**) to talk directly to any enabled
provider. The Intel NPU preset sends chat requests to the local OVMS endpoint; enabled custom
OpenAI-compatible providers use their configured endpoint and OS-stored API key.

Selecting terminal or document text and opening its context menu also exposes
**Analyze with Pebrel AI...**, which opens the same native chat with the selection pre-filled.

Pebrel's existing AI assistant can then use the selected provider for local terminal-error
analysis and command suggestions.

## Notes

- The NPU does not accelerate terminal drawing. GPUI/GPU continues to render the terminal.
- The NPU is intended for inference workloads such as terminal error analysis, local chat,
  summarization, classification, and other low-power AI tasks.
- Initial model download and NPU compilation can take time.
- NPU LLM support has model/quantization constraints; use models prepared for OpenVINO NPU.
- OVMS is explicitly bound to 127.0.0.1 by the script; do not expose the inference
  port publicly unless you add authentication and appropriate network controls.

---

# Intel NPU 支持（实验版）

此 fork 为 Windows AI PC 增加 **Intel NPU (OpenVINO)** 本地 AI 供应商。

第一阶段针对 Core Ultra 7 155H / Intel AI Boost。Pebrel 本身继续由 GPU 渲染，
NPU 专门承担本地 AI 推理。

在仓库目录打开 PowerShell 后执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\pebrel-npu.ps1 setup
```

完成后进入：

```text
设置 -> AI 供应商 -> Intel NPU (OpenVINO)
```

默认地址：

```text
http://127.0.0.1:8000/v3
```

默认模型：

```text
OpenVINO/Qwen3-8B-int4-cw-ov
```

不需要 API Key。

此供应商页会显示 **Intel NPU 运行服务** 状态，并提供 **刷新状态 / 启动 NPU /
停止 NPU**。Pebrel 只会停止自己管理并记录 PID 的 OVMS 进程；如果检测到外部启动的
OVMS，只显示状态，不会强制结束。

首次完成模型准备后，也可以创建桌面快捷方式：

```powershell
.\scripts\pebrel-npu.ps1 shortcut -PebrelExe ".\target\release\pebrel.exe"
```

会生成 **Start Pebrel NPU** 与 **Stop Pebrel NPU** 两个快捷方式。

原生 AI 对话入口：

```text
Ctrl+Shift+A
→ Pebrel AI Chat
→ 选择 Intel NPU (OpenVINO) 或已启用的第三方供应商
→ 输入问题并发送
```

在终端或文档中选中文字后右键，还可以选择 **用 Pebrel AI 分析...**，选中的内容会
自动带入对话框。

诊断命令：

```powershell
.\scripts\pebrel-npu.ps1 doctor
```

如果任务管理器中的 NPU 在生成回答时出现利用率变化，即表示推理已经实际进入
Intel AI Boost，而不是只运行在 CPU 上。
