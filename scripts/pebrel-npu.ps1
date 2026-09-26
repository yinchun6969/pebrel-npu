#requires -Version 5.1
<#
Pebrel Intel NPU helper for Windows 11 / Intel Core Ultra.

Examples:
  .\scripts\pebrel-npu.ps1 doctor
  .\scripts\pebrel-npu.ps1 setup
  .\scripts\pebrel-npu.ps1 stop
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("doctor","devices","install","model","repair-tokenizer","start","test","stop","setup")]
    [string]$Action = "doctor",

    [string]$Model = "OpenVINO/Qwen3-8B-int4-cw-ov",
    [int]$Port = 8000,
    [string]$HfEndpoint = "https://huggingface.co",
    [int]$GitConnectTimeoutMs = 60000,
    [int]$GitTransferTimeoutMs = 600000,
    [int]$LfsResumeAttempts = 20,
    [int]$LfsResumeIntervalSeconds = 15,
    [string]$PebrelNpuHome = (Join-Path $env:LOCALAPPDATA "PebrelNPU")
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RuntimeRoot = Join-Path $PebrelNpuHome "runtime"
$ModelsRoot = Join-Path $PebrelNpuHome "models"
$ConfigPath = Join-Path $ModelsRoot "config.json"
$PidPath = Join-Path $PebrelNpuHome "ovms.pid"
$LogPath = Join-Path $PebrelNpuHome "ovms.log"

function Write-Step([string]$Text) {
    Write-Host "[Pebrel NPU] $Text" -ForegroundColor Cyan
}

function Get-IntelNpuDevice {
    $found = @()

    # Newer Windows builds expose the NPU more reliably through Get-PnpDevice
    # than Win32_PnPEntity. Intel has used both "Intel(R) AI Boost" and
    # "Intel(R) NPU Accelerator" product names across driver generations.
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        $found += Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object {
                $name = [string]$_.FriendlyName
                $class = [string]$_.Class
                $id = [string]$_.InstanceId
                (
                    $name -match '(?i)Intel.*(AI Boost|NPU|Neural|VPU)' -or
                    ($id -match '(?i)^PCI\\VEN_8086' -and $class -match '(?i)Neural|Compute|Accelerator')
                )
            } |
            ForEach-Object {
                [pscustomobject]@{
                    Name = $_.FriendlyName
                    Status = $_.Status
                    Class = $_.Class
                    DeviceId = $_.InstanceId
                    Source = "Get-PnpDevice"
                }
            }
    }

    $found += Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object {
            $text = "$($_.Name) $($_.Caption) $($_.Description) $($_.PNPClass)"
            $text -match '(?i)Intel.*(AI Boost|NPU|Neural|VPU)' -or
            (($_.DeviceID -match '(?i)^PCI\\VEN_8086') -and ($_.PNPClass -match '(?i)Neural|Compute|Accelerator'))
        } |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Status = $_.Status
                Class = $_.PNPClass
                DeviceId = $_.DeviceID
                Source = "Win32_PnPEntity"
            }
        }

    $found += Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object {
            "$($_.DeviceName) $($_.DeviceClass)" -match '(?i)Intel.*(AI Boost|NPU|Neural|VPU)'
        } |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.DeviceName
                Status = "Driver installed"
                Class = $_.DeviceClass
                DeviceId = $_.DeviceID
                Source = "Win32_PnPSignedDriver"
            }
        }

    return @(
        $found |
            Where-Object { $_.Name -or $_.DeviceId } |
            Sort-Object DeviceId, Name -Unique
    )
}

function Get-IntelNpuDriverVersion {
    $driver = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceName -match '(?i)^Intel.*(AI Boost|NPU|Neural|VPU)' } |
        Select-Object -First 1
    if ($driver) { return [string]$driver.DriverVersion }
    return $null
}

function Show-SuspectDevices {
    Write-Host ""
    Write-Host "Windows NPU / accelerator candidates" -ForegroundColor White
    Write-Host "------------------------------------"

    $rows = @()
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        $rows += Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FriendlyName -match '(?i)AI Boost|NPU|Neural|VPU|Accelerator' -or
                ($_.InstanceId -match '(?i)^PCI\\VEN_8086' -and $_.Class -match '(?i)Neural|Compute|Accelerator')
            } |
            Select-Object Status, Class, FriendlyName, InstanceId
    }

    if ($rows.Count -eq 0) {
        Write-Host "No obvious NPU candidate was returned by Get-PnpDevice." -ForegroundColor Yellow
        Write-Host "Intel display/driver records that may help diagnosis:"
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { $_.Manufacturer -match '(?i)Intel' -and $_.DeviceName -match '(?i)AI|NPU|Neural|VPU|Accelerator' } |
            Select-Object DeviceName, DeviceClass, DriverVersion, DeviceID |
            Format-Table -AutoSize
    } else {
        $rows | Format-Table -AutoSize
    }
}

function Get-OvmsExe {
    if (Test-Path $RuntimeRoot) {
        $candidate = Get-ChildItem $RuntimeRoot -Filter "ovms.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    $cmd = Get-Command ovms.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-SetupVars([string]$OvmsExe) {
    if (-not $OvmsExe) { return $null }
    $dir = Split-Path $OvmsExe -Parent
    $found = Get-ChildItem $dir -Filter "setupvars.bat" -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $found -and (Test-Path $RuntimeRoot)) {
        $found = Get-ChildItem $RuntimeRoot -Filter "setupvars.bat" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($found) { return $found.FullName }
    return $null
}

function Invoke-Ovms {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$Detached
    )

    $ovms = Get-OvmsExe
    if (-not $ovms) {
        throw "ovms.exe was not found. Run: .\scripts\pebrel-npu.ps1 install"
    }

    $setupvars = Get-SetupVars $ovms
    $quotedArgs = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join " "

    if ($setupvars) {
        $command = 'call "' + $setupvars + '" >nul && "' + $ovms + '" ' + $quotedArgs
    } else {
        $command = '"' + $ovms + '" ' + $quotedArgs
    }

    if ($Detached) {
        New-Item -ItemType Directory -Force -Path $PebrelNpuHome | Out-Null
        $full = $command + ' >> "' + $LogPath + '" 2>&1'
        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d","/s","/c",$full) -WindowStyle Hidden -PassThru
        Set-Content -Path $PidPath -Value $proc.Id -Encoding ascii
        return $proc
    }

    & cmd.exe /d /s /c $command
    if ($LASTEXITCODE -ne 0) {
        throw ("OVMS exited with code " + $LASTEXITCODE + ". If this happened during model pull, OVMS can resume interrupted LFS downloads. The model command also retries the official hf-mirror endpoint automatically when the default Hugging Face endpoint fails.")
    }
}

function Install-Ovms {
    Write-Step "Finding the latest OpenVINO Model Server Windows package..."
    New-Item -ItemType Directory -Force -Path $PebrelNpuHome | Out-Null

    $headers = @{ "User-Agent" = "Pebrel-NPU" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/openvinotoolkit/model_server/releases/latest" -Headers $headers

    $asset = $release.assets |
        Where-Object { $_.name -match '^ovms_windows_.*_python_off\.zip$' } |
        Select-Object -First 1

    if (-not $asset) {
        throw "The latest OVMS release does not contain a Windows python_off ZIP."
    }

    $shaAsset = $release.assets |
        Where-Object { $_.name -eq ($asset.name + ".sha256") } |
        Select-Object -First 1

    $versionDir = Join-Path $RuntimeRoot $release.tag_name
    $zipPath = Join-Path $PebrelNpuHome $asset.name

    if (-not (Test-Path $versionDir)) {
        New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
        Write-Step "Downloading $($asset.name)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing

        if ($shaAsset) {
            $shaPath = $zipPath + ".sha256"
            Invoke-WebRequest -Uri $shaAsset.browser_download_url -OutFile $shaPath -UseBasicParsing
            $expectedText = Get-Content $shaPath -Raw
            $match = [regex]::Match($expectedText, '[A-Fa-f0-9]{64}')
            if (-not $match.Success) {
                throw "Could not parse OVMS SHA256 file."
            }
            $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $expected = $match.Value.ToLowerInvariant()
            if ($actual -ne $expected) {
                throw "OVMS SHA256 verification failed."
            }
            Write-Step "SHA256 verified."
        }

        Expand-Archive -Path $zipPath -DestinationPath $versionDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item ($zipPath + ".sha256") -Force -ErrorAction SilentlyContinue
    }

    $ovms = Get-OvmsExe
    if (-not $ovms) {
        throw "OVMS was downloaded but ovms.exe could not be located under $RuntimeRoot"
    }
    Write-Step "OVMS ready: $ovms"
}

function Test-EndpointTcp443([string]$Endpoint, [int]$TimeoutMs = 3000) {
    try {
        $uri = [Uri]$Endpoint
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($uri.DnsSafeHost, 443, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $ok) {
            $client.Close()
            return $false
        }
        $client.EndConnect($async)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

function Resolve-ModelEndpoint([string]$RequestedEndpoint) {
    if ($RequestedEndpoint -ne "https://huggingface.co") {
        return $RequestedEndpoint
    }

    $candidates = @(
        "https://huggingface.co",
        "https://hf-mirror.com",
        "https://www.modelscope.cn/models"
    )
    foreach ($candidate in $candidates) {
        Write-Step ("Checking model source: " + $candidate)
        if (Test-EndpointTcp443 $candidate) {
            Write-Step ("Selected reachable model source: " + $candidate)
            return $candidate
        }
        Write-Warning ("Model source is not reachable on TCP 443: " + $candidate)
    }

    throw "No configured model source is reachable on TCP 443."
}

function Repair-DefaultTokenizer {
    if ($Model -ne "OpenVINO/Qwen3-8B-int4-cw-ov") {
        throw "repair-tokenizer currently supports only OpenVINO/Qwen3-8B-int4-cw-ov"
    }

    $modelDir = Join-Path $ModelsRoot ($Model -replace "/", "\")
    New-Item -ItemType Directory -Force -Path $modelDir | Out-Null

    $target = Join-Path $modelDir "tokenizer.json"
    $temp = $target + ".download"
    $expectedSha256 = "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
    $url = "https://hf-mirror.com/OpenVINO/Qwen3-8B-int4-cw-ov/resolve/main/tokenizer.json?download=true"

    if (-not (Test-EndpointTcp443 "https://hf-mirror.com")) {
        throw "hf-mirror.com is not reachable on TCP 443; cannot repair tokenizer.json."
    }

    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    Write-Step "Downloading tokenizer.json directly from hf-mirror.com to bypass LFS range-resume issues..."

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { throw "curl.exe was not found on this Windows installation." }

    $curlArgs = @(
        "--location", "--fail", "--retry", "10", "--retry-delay", "3",
        "--retry-all-errors", "--connect-timeout", "20", "--max-time", "900",
        "--output", $temp, $url
    )
    & $curl.Source @curlArgs

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $temp)) {
        throw "Direct tokenizer.json download failed."
    }

    $actual = (Get-FileHash -Path $temp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expectedSha256) {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        throw ("tokenizer.json SHA256 mismatch. Expected " + $expectedSha256 + ", got " + $actual)
    }

    Move-Item -Path $temp -Destination $target -Force
    Remove-Item ($target + ".lfs_part") -Force -ErrorAction SilentlyContinue

    Write-Step "tokenizer.json repaired and SHA256 verified."
    Write-Step ("File: " + $target)
}
function Prepare-Model {
    # OVMS pull mode uses libgit2 for Hugging Face/LFS. Its defaults are only
    # 4000 ms for connect and transfer operations, which is too aggressive for
    # multi-GB models on many consumer networks.
    $effectiveHfEndpoint = Resolve-ModelEndpoint $HfEndpoint
    $env:HF_ENDPOINT = $effectiveHfEndpoint
    $env:GIT_OPT_SET_SERVER_CONNECT_TIMEOUT = [string]$GitConnectTimeoutMs
    $env:GIT_OPT_SET_SERVER_TIMEOUT = [string]$GitTransferTimeoutMs
    $env:GIT_LFS_RESUME_ATTEMPTS = [string]$LfsResumeAttempts
    $env:GIT_LFS_RESUME_INTERVAL_SECONDS = [string]$LfsResumeIntervalSeconds
    Write-Step ("Model source: " + $env:HF_ENDPOINT)
    Write-Step ("Git/LFS timeouts: connect=" + $env:GIT_OPT_SET_SERVER_CONNECT_TIMEOUT + " ms, transfer=" + $env:GIT_OPT_SET_SERVER_TIMEOUT + " ms")
    Write-Step ("LFS resume: attempts=" + $env:GIT_LFS_RESUME_ATTEMPTS + ", interval=" + $env:GIT_LFS_RESUME_INTERVAL_SECONDS + " s")

    $npu = @(Get-IntelNpuDevice)
    if ($npu.Count -eq 0) {
        Write-Warning "Windows enumeration did not identify the Intel NPU. Continuing anyway; OVMS --target_device NPU will be the authoritative hardware test."
    }

    New-Item -ItemType Directory -Force -Path $ModelsRoot | Out-Null
    $resumeMarkers = @(Get-ChildItem $ModelsRoot -Filter "*.lfswip" -File -Recurse -ErrorAction SilentlyContinue)
    if ($resumeMarkers.Count -gt 0) {
        Write-Step ("Found " + $resumeMarkers.Count + " persisted LFS resume marker(s); continuing partial downloads instead of restarting.")
    }
    $cache = Join-Path $ModelsRoot ".ov_cache"

    Write-Step "Pulling and compiling $Model for NPU. First run can take a while."
    $pullArgs = @(
        "--pull",
        "--source_model", $Model,
        "--model_repository_path", $ModelsRoot,
        "--target_device", "NPU",
        "--task", "text_generation",
        "--tool_parser", "hermes3",
        "--cache_dir", $cache,
        "--enable_prefix_caching", "true",
        "--max_prompt_len", "2000"
    )

    try {
        Invoke-Ovms -Arguments $pullArgs
    } catch {
        if ($HfEndpoint -eq "https://huggingface.co") {
            $fallbacks = @(
                "https://hf-mirror.com",
                "https://www.modelscope.cn/models"
            ) | Where-Object { $_ -ne $effectiveHfEndpoint }
            $lastError = $_
            $succeeded = $false
            foreach ($endpoint in $fallbacks) {
                if (-not (Test-EndpointTcp443 $endpoint)) {
                    Write-Warning ("Skipping unreachable fallback model source: " + $endpoint)
                    continue
                }
                try {
                    Write-Warning ("Retrying with fallback model source " + $endpoint + " ...")
                    $env:HF_ENDPOINT = $endpoint
                    Write-Step ("Fallback model source: " + $env:HF_ENDPOINT)
                    Invoke-Ovms -Arguments $pullArgs
                    $succeeded = $true
                    break
                } catch {
                    $lastError = $_
                }
            }
            if (-not $succeeded) { throw $lastError }
        } else {
            throw
        }
    }

    $modelRelative = $Model -replace "/", "\"
    $modelPath = Join-Path $ModelsRoot $modelRelative
    Write-Step "Writing OVMS config..."
    Invoke-Ovms -Arguments @(
        "--add_to_config",
        "--config_path", $ConfigPath,
        "--model_name", $Model,
        "--model_path", $modelPath
    )
}

function Start-Ovms {
    if (-not (Test-Path $ConfigPath)) {
        throw "Model config not found. Run: .\scripts\pebrel-npu.ps1 model"
    }

    if (Test-Path $PidPath) {
        $oldPid = (Get-Content $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
            Write-Step "OVMS is already running (PID $oldPid)."
            return
        }
    }

    Remove-Item $LogPath -Force -ErrorAction SilentlyContinue
    $proc = Invoke-Ovms -Arguments @("--rest_port", "$Port", "--rest_bind_address", "127.0.0.1", "--config_path", $ConfigPath) -Detached

    Write-Step "Started OVMS PID $($proc.Id) on http://127.0.0.1:$Port"
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/config" -TimeoutSec 2
            Write-Step "Model server is ready."
            return
        } catch {}
    }
    Write-Warning "OVMS did not become ready within 120 seconds. Check: $LogPath"
}

function Stop-Ovms {
    if (-not (Test-Path $PidPath)) {
        Write-Step "No managed OVMS PID file found."
        return
    }
    $id = (Get-Content $PidPath | Select-Object -First 1)
    if ($id -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $id -Force
        Write-Step "Stopped OVMS PID $id."
    }
    Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
}

function Test-NpuChat {
    $models = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 5
    Write-Step ("OVMS models endpoint OK. Models: " + (($models.data.id) -join ", "))

    $body = @{
        model = $Model
        max_tokens = 48
        temperature = 0
        stream = $false
        chat_template_kwargs = @{ enable_thinking = $false }
        messages = @(
            @{ role = "system"; content = "You are a concise terminal assistant." },
            @{ role = "user"; content = "Reply with exactly: PEBREL_NPU_OK" }
        )
    } | ConvertTo-Json -Depth 8

    $result = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 120
    $reply = $result.choices[0].message.content
    Write-Host "NPU response: $reply"
}

function Show-Doctor {
    Write-Host ""
    Write-Host "Pebrel NPU doctor" -ForegroundColor White
    Write-Host "-----------------"

    $npu = @(Get-IntelNpuDevice)
    if ($npu.Count -gt 0) {
        foreach ($d in $npu) {
            Write-Host ("[OK] NPU candidate: " + $d.Name) -ForegroundColor Green
            if ($d.Status) { Write-Host ("     status: " + $d.Status) }
            if ($d.Class) { Write-Host ("     class:  " + $d.Class) }
            if ($d.Source) { Write-Host ("     source: " + $d.Source) }
        }
        $driverVersion = Get-IntelNpuDriverVersion
        if ($driverVersion) { Write-Host ("[OK] Intel NPU driver: " + $driverVersion) -ForegroundColor Green }
    } else {
        Write-Host "[WARN] Windows inventory did not expose an Intel NPU through the known APIs." -ForegroundColor Yellow
        Write-Host "       This does NOT prove the NPU is absent. If Task Manager shows NPU, run:" -ForegroundColor Yellow
        Write-Host "       .\scripts\pebrel-npu.ps1 devices" -ForegroundColor Yellow
        Write-Host "       The authoritative test is OVMS with --target_device NPU." -ForegroundColor Yellow
    }

    $ovms = Get-OvmsExe
    if ($ovms) {
        Write-Host "[OK] OVMS: $ovms" -ForegroundColor Green
    } else {
        Write-Host "[MISS] OVMS not installed by Pebrel NPU" -ForegroundColor Yellow
    }

    if (Test-Path $ConfigPath) {
        Write-Host "[OK] model config: $ConfigPath" -ForegroundColor Green
    } else {
        Write-Host "[MISS] model config not prepared" -ForegroundColor Yellow
    }

    try {
        $cfg = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/config" -TimeoutSec 2
        Write-Host "[OK] OVMS endpoint: http://127.0.0.1:$Port" -ForegroundColor Green
        $cfg | ConvertTo-Json -Depth 6
    } catch {
        Write-Host "[OFF] OVMS endpoint is not responding" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Pebrel provider defaults:"
    Write-Host "  Endpoint: http://127.0.0.1:$Port/v1"
    Write-Host "  Model:    $Model"
    Write-Host "  API key:  none"
}

switch ($Action) {
    "doctor"  { Show-Doctor }
    "devices" { Show-SuspectDevices }
    "install" { Install-Ovms; Show-Doctor }
    "model"   { Prepare-Model }
    "repair-tokenizer" { Repair-DefaultTokenizer }
    "start"   { Start-Ovms }
    "test"    { Test-NpuChat }
    "stop"    { Stop-Ovms }
    "setup"   {
        Install-Ovms
        Prepare-Model
        Start-Ovms
        Test-NpuChat
        Show-Doctor
    }
}
