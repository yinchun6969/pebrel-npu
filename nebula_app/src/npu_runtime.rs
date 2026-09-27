//! Intel NPU runtime lifecycle for the local OpenVINO Model Server.
//!
//! The settings UI owns presentation only. This module owns discovery, readiness
//! probing and the Windows child-process lifecycle for the loopback OVMS service.

use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NpuRuntimeStatus {
    Unsupported,
    NotInstalled,
    NotConfigured,
    Stopped,
    Running { managed: bool, model_available: bool },
    Error(String),
}

impl NpuRuntimeStatus {
    pub fn is_running(&self) -> bool {
        matches!(self, Self::Running { .. })
    }

    pub fn is_managed_running(&self) -> bool {
        matches!(self, Self::Running { managed: true, .. })
    }

    pub fn model_available(&self) -> bool {
        matches!(self, Self::Running { model_available: true, .. })
    }
}

#[derive(Clone, Debug)]
struct RuntimePaths {
    home: PathBuf,
    runtime_root: PathBuf,
    config: PathBuf,
    pid: PathBuf,
    log: PathBuf,
}

impl RuntimePaths {
    fn discover() -> Result<Self, String> {
        let local = std::env::var_os("LOCALAPPDATA")
            .ok_or_else(|| "LOCALAPPDATA is not available".to_owned())?;
        let home = PathBuf::from(local).join("PebrelNPU");
        Ok(Self {
            runtime_root: home.join("runtime"),
            config: home.join("models").join("config.json"),
            pid: home.join("ovms.pid"),
            log: home.join("ovms.log"),
            home,
        })
    }
}

enum ProbeError {
    Unreachable,
    Other(String),
}

fn loopback_port(base_url: &str) -> Result<u16, String> {
    let trimmed = base_url.trim().trim_end_matches('/');
    let authority = trimmed
        .strip_prefix("http://")
        .ok_or_else(|| "Intel NPU runtime endpoint must use http:// on loopback".to_owned())?
        .split('/')
        .next()
        .unwrap_or_default();

    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => {
            let port = port
                .parse::<u16>()
                .map_err(|_| format!("Invalid Intel NPU runtime port: {port}"))?;
            (host, port)
        },
        None => (authority, 8000),
    };
    if !matches!(host, "127.0.0.1" | "localhost") {
        return Err("Intel NPU runtime management is limited to 127.0.0.1/localhost".to_owned());
    }
    Ok(port)
}

fn probe_model(model: &str, port: u16) -> Result<bool, ProbeError> {
    let url = format!("http://127.0.0.1:{port}/v1/config");
    let config = ureq::config::Config::builder()
        .timeout_global(Some(Duration::from_secs(3)))
        .http_status_as_error(false)
        .build();
    let agent: ureq::Agent = config.new_agent();
    let mut response = match agent.get(&url).call() {
        Ok(response) => response,
        Err(
            ureq::Error::ConnectionFailed
            | ureq::Error::HostNotFound
            | ureq::Error::Timeout(_)
            | ureq::Error::Io(_),
        ) => return Err(ProbeError::Unreachable),
        Err(error) => return Err(ProbeError::Other(format!("OVMS probe failed: {error}"))),
    };

    let status = response.status().as_u16();
    if !(200..=299).contains(&status) {
        return Err(ProbeError::Other(format!("OVMS returned HTTP {status} from /v1/config")));
    }
    let value: serde_json::Value = response
        .body_mut()
        .read_json()
        .map_err(|error| ProbeError::Other(format!("OVMS returned invalid config JSON: {error}")))?;

    let available = value
        .get(model)
        .and_then(|entry| entry.get("model_version_status"))
        .and_then(serde_json::Value::as_array)
        .is_some_and(|versions| {
            versions.iter().any(|version| {
                version.get("state").and_then(serde_json::Value::as_str) == Some("AVAILABLE")
                    && version
                        .get("status")
                        .and_then(|status| status.get("error_code"))
                        .and_then(serde_json::Value::as_str)
                        == Some("OK")
            })
        });
    Ok(available)
}

fn read_pid(path: &Path) -> Option<u32> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn find_named_file(root: &Path, name: &str) -> Option<PathBuf> {
    if !root.is_dir() {
        return None;
    }
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else if path
                .file_name()
                .and_then(|value| value.to_str())
                .is_some_and(|value| value.eq_ignore_ascii_case(name))
            {
                return Some(path);
            }
        }
    }
    None
}

fn inspect_with_paths(model: &str, port: u16, paths: &RuntimePaths) -> NpuRuntimeStatus {
    match probe_model(model, port) {
        Ok(model_available) => {
            return NpuRuntimeStatus::Running {
                managed: read_pid(&paths.pid).is_some(),
                model_available,
            };
        },
        Err(ProbeError::Other(error)) => return NpuRuntimeStatus::Error(error),
        Err(ProbeError::Unreachable) => {},
    }

    if find_named_file(&paths.runtime_root, "ovms.exe").is_none() {
        NpuRuntimeStatus::NotInstalled
    } else if !paths.config.is_file() {
        NpuRuntimeStatus::NotConfigured
    } else {
        NpuRuntimeStatus::Stopped
    }
}

pub fn inspect(model: &str, base_url: &str) -> NpuRuntimeStatus {
    #[cfg(not(windows))]
    {
        let _ = (model, base_url);
        return NpuRuntimeStatus::Unsupported;
    }

    #[cfg(windows)]
    {
        let port = match loopback_port(base_url) {
            Ok(port) => port,
            Err(error) => return NpuRuntimeStatus::Error(error),
        };
        let paths = match RuntimePaths::discover() {
            Ok(paths) => paths,
            Err(error) => return NpuRuntimeStatus::Error(error),
        };
        inspect_with_paths(model, port, &paths)
    }
}

#[cfg(windows)]
fn command_fragment(path: &Path) -> String {
    format!("\"{}\"", path.display())
}

#[cfg(windows)]
fn spawn_hidden_ovms(paths: &RuntimePaths, port: u16) -> Result<std::process::Child, String> {
    use std::fs::OpenOptions;
    use std::os::windows::process::CommandExt as _;
    use std::process::{Command, Stdio};

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let ovms = find_named_file(&paths.runtime_root, "ovms.exe")
        .ok_or_else(|| "ovms.exe was not found under the Pebrel NPU runtime".to_owned())?;
    let setupvars = find_named_file(&paths.runtime_root, "setupvars.bat");

    std::fs::create_dir_all(&paths.home)
        .map_err(|error| format!("Could not create Pebrel NPU directory: {error}"))?;
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&paths.log)
        .map_err(|error| format!("Could not open OVMS log: {error}"))?;
    let stderr = log
        .try_clone()
        .map_err(|error| format!("Could not clone OVMS log handle: {error}"))?;

    let arguments = format!(
        "{} --rest_port {} --rest_bind_address 127.0.0.1 --config_path {}",
        command_fragment(&ovms),
        port,
        command_fragment(&paths.config),
    );
    let command = match setupvars {
        Some(setupvars) => {
            format!("call {} >nul && {arguments}", command_fragment(&setupvars))
        },
        None => arguments,
    };

    Command::new("cmd.exe")
        .args(["/d", "/s", "/c", &command])
        .current_dir(&paths.home)
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(stderr))
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|error| format!("Could not start OVMS: {error}"))
}

pub fn start(model: &str, base_url: &str) -> Result<NpuRuntimeStatus, String> {
    #[cfg(not(windows))]
    {
        let _ = (model, base_url);
        return Err("Intel NPU runtime management is currently available on Windows only".into());
    }

    #[cfg(windows)]
    {
        let port = loopback_port(base_url)?;
        let paths = RuntimePaths::discover()?;
        match inspect_with_paths(model, port, &paths) {
            status @ NpuRuntimeStatus::Running { model_available: true, .. } => return Ok(status),
            NpuRuntimeStatus::Running { model_available: false, .. } => {
                return Err(format!(
                    "OVMS is already running on port {port}, but model {model} is not AVAILABLE"
                ));
            },
            NpuRuntimeStatus::NotInstalled => {
                return Err("OVMS is not installed. Run Pebrel NPU setup once first.".into());
            },
            NpuRuntimeStatus::NotConfigured => {
                return Err("The Pebrel NPU model config is missing. Run model setup once first.".into());
            },
            NpuRuntimeStatus::Error(error) => return Err(error),
            NpuRuntimeStatus::Unsupported => {
                return Err("Intel NPU runtime management is unsupported on this platform".into());
            },
            NpuRuntimeStatus::Stopped => {},
        }

        let mut child = spawn_hidden_ovms(&paths, port)?;
        std::fs::write(&paths.pid, child.id().to_string())
            .map_err(|error| format!("OVMS started, but its PID could not be saved: {error}"))?;

        for _ in 0..240 {
            if let Some(status) = child
                .try_wait()
                .map_err(|error| format!("Could not query OVMS process state: {error}"))?
            {
                let _ = std::fs::remove_file(&paths.pid);
                return Err(format!(
                    "OVMS exited before becoming ready ({status}). Check {}",
                    paths.log.display()
                ));
            }
            match probe_model(model, port) {
                Ok(true) => {
                    return Ok(NpuRuntimeStatus::Running {
                        managed: true,
                        model_available: true,
                    });
                },
                Ok(false) | Err(ProbeError::Unreachable) => {},
                Err(ProbeError::Other(error)) => return Err(error),
            }
            std::thread::sleep(Duration::from_millis(500));
        }

        Err(format!(
            "OVMS did not make model {model} AVAILABLE within 120 seconds. Check {}",
            paths.log.display()
        ))
    }
}

pub fn stop(model: &str, base_url: &str) -> Result<NpuRuntimeStatus, String> {
    #[cfg(not(windows))]
    {
        let _ = (model, base_url);
        return Err("Intel NPU runtime management is currently available on Windows only".into());
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        use std::process::{Command, Stdio};

        const CREATE_NO_WINDOW: u32 = 0x0800_0000;

        let port = loopback_port(base_url)?;
        let paths = RuntimePaths::discover()?;
        let before = inspect_with_paths(model, port, &paths);
        if !before.is_running() {
            let _ = std::fs::remove_file(&paths.pid);
            return Ok(before);
        }

        let pid = read_pid(&paths.pid).ok_or_else(|| {
            "OVMS is running, but Pebrel does not own its PID. Stop that external OVMS process manually."
                .to_owned()
        })?;
        let status = Command::new("taskkill.exe")
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .status()
            .map_err(|error| format!("Could not stop OVMS process tree: {error}"))?;
        if !status.success() {
            return Err(format!("taskkill could not stop managed OVMS PID {pid}"));
        }
        let _ = std::fs::remove_file(&paths.pid);

        for _ in 0..20 {
            match probe_model(model, port) {
                Err(ProbeError::Unreachable) => return Ok(inspect_with_paths(model, port, &paths)),
                Ok(_) => std::thread::sleep(Duration::from_millis(250)),
                Err(ProbeError::Other(error)) => return Err(error),
            }
        }
        Err("OVMS still responds after the managed process was stopped".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_runtime_port_accepts_only_loopback_http() {
        assert_eq!(loopback_port("http://127.0.0.1:8000/v3").unwrap(), 8000);
        assert_eq!(loopback_port("http://localhost:9000/v3/").unwrap(), 9000);
        assert!(loopback_port("https://127.0.0.1:8000/v3").is_err());
        assert!(loopback_port("http://192.168.1.2:8000/v3").is_err());
    }

    #[test]
    fn runtime_status_helpers_are_precise() {
        let managed = NpuRuntimeStatus::Running { managed: true, model_available: true };
        let unmanaged = NpuRuntimeStatus::Running { managed: false, model_available: true };
        let loading = NpuRuntimeStatus::Running { managed: true, model_available: false };
        assert!(managed.is_running());
        assert!(managed.is_managed_running());
        assert!(managed.model_available());
        assert!(unmanaged.is_running());
        assert!(!unmanaged.is_managed_running());
        assert!(!loading.model_available());
        assert!(!NpuRuntimeStatus::Stopped.is_running());
    }
}
