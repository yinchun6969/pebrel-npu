# Local Intel NPU runtime lifecycle

## Status

Accepted for the `feature/intel-npu-v1` experiment.

## Context

Pebrel can use an OpenAI-compatible local provider backed by OpenVINO Model Server
(OVMS) and an Intel NPU. The first implementation required users to start and stop
OVMS from a PowerShell helper. That proved the hardware path, but it left lifecycle
knowledge outside the application and made the AI provider page unable to explain
whether the local service was ready.

The provider UI must not synchronously probe the network or own child-process rules.
The existing NPU helper also binds OVMS to `127.0.0.1`, so in-app lifecycle
management must preserve that boundary rather than becoming a generic process manager.

## Evidence

- `scripts/pebrel-npu.ps1` already owns the installation/model-preparation workflow
  and writes `%LOCALAPPDATA%\PebrelNPU\ovms.pid`.
- The validated local model is reported as `AVAILABLE` with `error_code=OK` by
  `GET /v1/config`.
- The same OVMS instance has returned a real response from `POST /v3/chat/completions`.
- Settings provider tests already run blocking HTTP work on the GPUI background
  executor and guard stale completions with sequence numbers.

## Decision

Add `nebula_app::npu_runtime` as the application capability that owns local OVMS
runtime discovery, readiness probing, start and stop operations.

The capability:

- accepts only loopback HTTP endpoints (`127.0.0.1` or `localhost`);
- launches OVMS with `--rest_bind_address 127.0.0.1`;
- reuses the existing `%LOCALAPPDATA%\PebrelNPU` runtime, model config, log and PID;
- starts through `setupvars.bat` when present so the Windows runtime environment
  matches the proven PowerShell path;
- reports ready only when the selected model is `AVAILABLE` and its status is `OK`;
- stops only a process tree whose PID was recorded by Pebrel/the helper;
- refuses to kill an externally managed OVMS process merely because it answers on
  the same port.

The AI Providers settings page invokes these operations on its background executor.
A sequence token invalidates stale results when the selected provider changes.

Installation and multi-gigabyte model preparation remain in the helper for this
iteration. The Settings page manages an already prepared runtime; it does not hide a
large first-time download behind a normal Start button.

## Rejected alternatives

1. Run PowerShell synchronously from the Settings view.
   Rejected because renderer callbacks must not block on subprocess or network work,
   and the installed product cannot assume a repository checkout path.

2. Kill whatever process owns port 8000.
   Rejected because a loopback listener may belong to another user-managed service.
   Stop is allowed only when Pebrel has a managed PID.

3. Run OVMS permanently at Windows login by default.
   Rejected because the model may retain substantial memory even when the user is not
   using local AI. Explicit start/stop and the desktop launcher are safer defaults.

4. Embed OVMS into the Pebrel process.
   Rejected for this experiment because OVMS is already a separately versioned native
   runtime with its own DLL environment and model lifecycle.

## Consequences

- Users can inspect, start and stop the prepared Intel NPU runtime from the provider
  page without typing the helper command each time.
- Closing Pebrel does not implicitly kill OVMS; explicit Stop remains the ownership
  boundary for the managed service.
- A separately launched OVMS is shown as external/unmanaged and cannot be stopped by
  the Pebrel button.
- First-time installation/model download is still a distinct setup step.

## Validation

Required before the draft PR is considered ready:

- Windows release build with the GPUI product feature.
- Unit tests for loopback endpoint parsing and runtime status helpers.
- On the Intel Core Ultra test machine, verify Refresh -> Running, Stop -> Stopped,
  Start -> Running/model available.
- Re-run the existing provider connection test after Start.
- Visual check of normal, busy, success, stopped and error states in the real Settings
  page.
- Verify that an OVMS instance without the managed PID is not killed.

## Supersedes

None.

## Revisit when

- OVMS is packaged directly with Pebrel rather than installed into PebrelNPU runtime;
- the application owns first-time model installation/download;
- OpenVINO provides an in-process API with a smaller and simpler lifecycle boundary;
- a product requirement calls for opt-in login startup or automatic on-demand startup.
