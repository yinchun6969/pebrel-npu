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
    [ValidateSet("doctor","devices","install","model","repair-tokenizer","repair-file","finalize-model","start","test","stop","launch","shortcut","setup")]
    [string]$Action = "doctor",

    [string]$Model = "OpenVINO/Qwen3-8B-int4-cw-ov",
    [int]$Port = 8000,
    [string]$HfEndpoint = "https://huggingface.co",
    [int]$GitConnectTimeoutMs = 60000,
    [int]$GitTransferTimeoutMs = 600000,
    [int]$LfsResumeAttempts = 20,
    [int]$LfsResumeIntervalSeconds = 15,
    [string]$RepairFile = "",
    [string]$PebrelExe = "",
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

function Invoke-NoRedirectRequest([string]$Url) {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "GET"
    $request.AllowAutoRedirect = $false
    $request.UserAgent = "Pebrel-NPU/1.0"
    $request.Timeout = 120000
    $request.ReadWriteTimeout = 120000
    try {
        return $request.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { return $_.Exception.Response }
        throw
    }
}

function Resolve-RedirectUrl([string]$Current, [System.Net.WebResponse]$Response) {
    $status = [int]$Response.StatusCode
    if ($status -notin 301,302,303,307,308) { return $null }
    $location = $Response.Headers["Location"]
    if ([string]::IsNullOrWhiteSpace($location)) {
        throw ("Redirect " + $status + " did not include a Location header.")
    }
    $baseUri = New-Object System.Uri($Current)
    return (New-Object System.Uri($baseUri, $location)).AbsoluteUri
}

function Get-TextWithRedirects([string]$InitialUrl) {
    $current = $InitialUrl
    for ($redirect = 0; $redirect -lt 12; $redirect++) {
        $response = Invoke-NoRedirectRequest $current
        try {
            $next = Resolve-RedirectUrl -Current $current -Response $response
            if ($next) {
                Write-Step ("Redirect " + ([int]$response.StatusCode) + " -> " + $next)
                $current = $next
                continue
            }
            $status = [int]$response.StatusCode
            if ($status -lt 200 -or $status -ge 300) { throw ("HTTP " + $status + " for " + $current) }
            $stream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
        } finally { $response.Dispose() }
    }
    throw "Too many redirects."
}

function Save-FileWithRedirects([string]$InitialUrl, [string]$Destination) {
    $current = $InitialUrl
    for ($redirect = 0; $redirect -lt 12; $redirect++) {
        $response = Invoke-NoRedirectRequest $current
        try {
            $next = Resolve-RedirectUrl -Current $current -Response $response
            if ($next) {
                Write-Step ("Redirect " + ([int]$response.StatusCode) + " -> " + $next)
                $current = $next
                continue
            }
            $status = [int]$response.StatusCode
            if ($status -lt 200 -or $status -ge 300) { throw ("HTTP " + $status + " for " + $current) }
            $input = $response.GetResponseStream()
            $output = [System.IO.File]::Open($Destination,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] 1048576
                while (($read = $input.Read($buffer,0,$buffer.Length)) -gt 0) { $output.Write($buffer,0,$read) }
            } finally {
                $output.Dispose()
                $input.Dispose()
            }
            return
        } finally { $response.Dispose() }
    }
    throw "Too many redirects."
}

function Save-RangeWithRedirects([string]$InitialUrl, [string]$Destination, [int64]$Start, [int64]$End) {
    $current = $InitialUrl
    for ($redirect = 0; $redirect -lt 12; $redirect++) {
        $request = [System.Net.HttpWebRequest]::Create($current)
        $request.Method = "GET"
        $request.AllowAutoRedirect = $false
        $request.UserAgent = "Pebrel-NPU/1.0"
        $request.Timeout = 120000
        $request.ReadWriteTimeout = 120000
        $request.AddRange($Start, $End)

        $response = $null
        try {
            try {
                $response = $request.GetResponse()
            } catch [System.Net.WebException] {
                if ($_.Exception.Response) { $response = $_.Exception.Response } else { throw }
            }

            $next = Resolve-RedirectUrl -Current $current -Response $response
            if ($next) {
                Write-Step ("Redirect " + ([int]$response.StatusCode) + " -> " + $next)
                $current = $next
                continue
            }

            $status = [int]$response.StatusCode
            if ($status -ne 206) {
                throw ("Server did not honor byte range " + $Start + "-" + $End + "; HTTP status=" + $status)
            }

            $remaining = ($End - $Start + 1)
            $input = $response.GetResponseStream()
            $output = [System.IO.File]::Open($Destination,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
            try {
                $output.Seek($Start,[System.IO.SeekOrigin]::Begin) | Out-Null
                $buffer = New-Object byte[] 1048576
                while ($remaining -gt 0) {
                    $want = [int][Math]::Min([int64]$buffer.Length, $remaining)
                    $read = $input.Read($buffer,0,$want)
                    if ($read -le 0) { throw ("Connection ended before range completed; " + $remaining + " bytes still missing.") }
                    $output.Write($buffer,0,$read)
                    $remaining -= $read
                }
            } finally {
                $output.Dispose()
                $input.Dispose()
            }
            return
        } finally {
            if ($response) { $response.Dispose() }
        }
    }
    throw "Too many redirects during ranged download."
}

function Save-LargeFileResumable([string]$DownloadUrl, [string]$Target, [int64]$ExpectedSize) {
    $part = $Target + ".repair_part"
    $ovmsPart = $Target + ".lfs_part"

    if (-not (Test-Path $part) -and (Test-Path $ovmsPart)) {
        Write-Step "Adopting the existing OVMS .lfs_part file so completed bytes are not downloaded again."
        Move-Item -Path $ovmsPart -Destination $part -Force
    }

    $offset = 0
    if (Test-Path $part) { $offset = [int64](Get-Item $part).Length }
    if ($offset -gt $ExpectedSize) {
        Remove-Item $part -Force
        $offset = 0
    }

    $chunkSize = [int64](64MB)
    Write-Step ("Large-file resume starts at " + $offset + " / " + $ExpectedSize + " bytes.")

    while ($offset -lt $ExpectedSize) {
        $end = [Math]::Min($offset + $chunkSize - 1, $ExpectedSize - 1)
        $done = $false
        $lastError = $null
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                Write-Step ("Range " + $offset + "-" + $end + " (attempt " + $attempt + "/10)")
                Save-RangeWithRedirects -InitialUrl $DownloadUrl -Destination $part -Start $offset -End $end
                $done = $true
                break
            } catch {
                $lastError = $_
                Write-Warning ("Range download failed: " + $_.Exception.Message)
                Start-Sleep -Seconds 3
            }
        }
        if (-not $done) { throw $lastError }
        $offset = [int64](Get-Item $part).Length
        if ($offset -lt ($end + 1)) { throw "Ranged download did not advance to the expected offset." }
    }

    Move-Item -Path $part -Destination ($Target + ".download") -Force
}
function Repair-ModelLfsFile([string]$FileName) {
    if ([string]::IsNullOrWhiteSpace($FileName)) { throw "Repair file name is empty." }
    if ([System.IO.Path]::GetFileName($FileName) -ne $FileName) { throw "RepairFile must be a single file name, not a path." }

    $modelDir = Join-Path $ModelsRoot ($Model -replace "/", "\")
    New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
    $target = Join-Path $modelDir $FileName
    $temp = $target + ".download"

    $base = "https://hf-mirror.com/" + $Model
    $pointerUrl = $base + "/raw/main/" + $FileName
    $downloadUrl = $base + "/resolve/main/" + $FileName + "?download=true"

    Write-Step ("Reading LFS pointer metadata for " + $FileName + "...")
    $pointer = Get-TextWithRedirects $pointerUrl
    $shaMatch = [regex]::Match($pointer, "oid sha256:([0-9a-fA-F]{64})")
    $sizeMatch = [regex]::Match($pointer, "(?m)^size ([0-9]+)$")
    if (-not $shaMatch.Success -or -not $sizeMatch.Success) {
        throw ("Could not parse LFS pointer metadata for " + $FileName)
    }
    $expectedSha256 = $shaMatch.Groups[1].Value.ToLowerInvariant()
    $expectedSize = [int64]$sizeMatch.Groups[1].Value
    Write-Step ("Expected size=" + $expectedSize + " bytes sha256=" + $expectedSha256)

    $largeThreshold = [int64](256MB)
    if ($expectedSize -ge $largeThreshold) {
        Write-Step ("Large LFS file detected (" + $expectedSize + " bytes); using 64 MiB ranged resume.")
        Save-LargeFileResumable -DownloadUrl $downloadUrl -Target $target -ExpectedSize $expectedSize
    } else {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        $lastError = $null
        $downloaded = $false
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                Write-Step ("Downloading " + $FileName + " (attempt " + $attempt + "/10)...")
                Save-FileWithRedirects -InitialUrl $downloadUrl -Destination $temp
                $downloaded = $true
                break
            } catch {
                $lastError = $_
                Remove-Item $temp -Force -ErrorAction SilentlyContinue
                Write-Warning ($FileName + " download failed: " + $_.Exception.Message)
                Start-Sleep -Seconds 3
            }
        }
        if (-not $downloaded) { throw $lastError }
    }

    $actualSize = (Get-Item $temp).Length
    if ($actualSize -ne $expectedSize) {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        throw ("Size mismatch for " + $FileName + ". Expected " + $expectedSize + ", got " + $actualSize)
    }
    $actualSha256 = (Get-FileHash -Path $temp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
        throw ("SHA256 mismatch for " + $FileName + ". Expected " + $expectedSha256 + ", got " + $actualSha256)
    }

    Move-Item -Path $temp -Destination $target -Force
    Remove-Item ($target + ".lfs_part") -Force -ErrorAction SilentlyContinue
    Remove-Item ($target + ".lfswip") -Force -ErrorAction SilentlyContinue
    Write-Step ($FileName + " repaired; size and SHA256 verified.")
}

function Repair-DefaultTokenizer {
    Repair-ModelLfsFile "tokenizer.json"
}
function Finalize-LocalModel {
    $modelDir = Join-Path $ModelsRoot ($Model -replace "/", "\")
    if (-not (Test-Path $modelDir)) { throw ("Model directory not found: " + $modelDir) }

    $required = @(
        "added_tokens.json",
        "chat_template.jinja",
        "config.json",
        "generation_config.json",
        "merges.txt",
        "openvino_config.json",
        "openvino_detokenizer.bin",
        "openvino_detokenizer.xml",
        "openvino_model.bin",
        "openvino_model.xml",
        "openvino_tokenizer.bin",
        "openvino_tokenizer.xml",
        "special_tokens_map.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "vocab.json"
    )

    $missing = @()
    foreach ($name in $required) {
        $p = Join-Path $modelDir $name
        if (-not (Test-Path $p) -or (Get-Item $p).Length -le 0) { $missing += $name }
    }
    if ($missing.Count -gt 0) {
        throw ("Cannot finalize local model; missing/empty required files: " + ($missing -join ", "))
    }

    $criticalSizes = @{
        "openvino_model.bin" = [int64]4700000000
        "openvino_tokenizer.bin" = [int64]5000000
        "openvino_detokenizer.bin" = [int64]2000000
        "tokenizer.json" = [int64]10000000
    }
    foreach ($name in $criticalSizes.Keys) {
        $p = Join-Path $modelDir $name
        $len = [int64](Get-Item $p).Length
        if ($len -lt $criticalSizes[$name]) {
            throw ("Refusing to finalize; " + $name + " is unexpectedly small (" + $len + " bytes).")
        }
    }

    $gitPath = Join-Path $modelDir ".git"
    if (Test-Path $gitPath) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backup = Join-Path $modelDir (".git.pebrel-backup-" + $stamp)
        Write-Step ("Preserving interrupted Git metadata as " + $backup)
        Move-Item -Path $gitPath -Destination $backup -Force
    }

    $marker = $modelDir + ".lfswip"
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $modelDir "lfs_error.txt") -Force -ErrorAction SilentlyContinue
    Get-ChildItem $modelDir -Filter "*.lfs_part" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Step "Local model finalized. OVMS will now treat this as a user-provided model directory and skip Hugging Face download/resume logic."
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
    $cfg = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/config" -TimeoutSec 10
    $cfgJson = $cfg | ConvertTo-Json -Depth 8
    if ($cfgJson -notmatch [regex]::Escape($Model)) {
        throw ("OVMS is running but the requested model is not present in /v1/config: " + $Model)
    }
    Write-Step ("OVMS config endpoint OK. Model is registered: " + $Model)

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

    $result = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v3/chat/completions" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 180
    $reply = $result.choices[0].message.content
    Write-Host "NPU response: $reply"
}

function Resolve-PebrelExe {
    if (-not [string]::IsNullOrWhiteSpace($PebrelExe)) {
        if (Test-Path $PebrelExe) { return (Resolve-Path $PebrelExe).Path }
        throw ("Pebrel executable not found: " + $PebrelExe)
    }

    $candidates = @(
        (Join-Path $PSScriptRoot "..\target\release\pebrel.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Pebrel\pebrel.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }

    $cmd = Get-Command pebrel.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "pebrel.exe was not found. Build Pebrel first or pass -PebrelExe <path>."
}

function Launch-PebrelWithNpu {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/config" -TimeoutSec 2 | Out-Null
        Write-Step "OVMS is already ready."
    } catch {
        Write-Step "OVMS is not ready; starting the Intel NPU runtime..."
        Start-Ovms
    }

    $exe = Resolve-PebrelExe
    Write-Step ("Launching Pebrel: " + $exe)
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) | Out-Null
}

function Install-PebrelNpuShortcuts {
    New-Item -ItemType Directory -Force -Path $PebrelNpuHome | Out-Null
    $stableScript = Join-Path $PebrelNpuHome "pebrel-npu.ps1"
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "Cannot install shortcuts because the helper script path is unavailable."
    }
    Copy-Item -Path $PSCommandPath -Destination $stableScript -Force

    $exe = Resolve-PebrelExe
    $desktop = [Environment]::GetFolderPath("Desktop")
    $shell = New-Object -ComObject WScript.Shell
    $powershell = Join-Path $PSHOME "powershell.exe"

    $legacyLaunch = Join-Path $desktop "Pebrel NPU.lnk"
    Remove-Item $legacyLaunch -Force -ErrorAction SilentlyContinue

    $startPath = Join-Path $desktop "Start Pebrel NPU.lnk"
    $launchLink = $shell.CreateShortcut($startPath)
    $launchLink.TargetPath = $powershell
    $launchLink.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $stableScript + '" launch -PebrelExe "' + $exe + '"'
    $launchLink.WorkingDirectory = Split-Path $exe -Parent
    $launchLink.IconLocation = $exe + ",0"
    $launchLink.WindowStyle = 7
    $launchLink.Description = "Start Intel NPU runtime if needed, then open Pebrel"
    $launchLink.Save()
    if (-not (Test-Path $startPath)) {
        throw ("Failed to create desktop shortcut: " + $startPath)
    }

    $stopPath = Join-Path $desktop "Stop Pebrel NPU.lnk"
    $stopLink = $shell.CreateShortcut($stopPath)
    $stopLink.TargetPath = $powershell
    $stopLink.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $stableScript + '" stop'
    $stopLink.WorkingDirectory = $PebrelNpuHome
    $stopLink.WindowStyle = 7
    $stopLink.Description = "Stop the Pebrel Intel NPU runtime"
    $stopLink.Save()
    if (-not (Test-Path $stopPath)) {
        throw ("Failed to create desktop shortcut: " + $stopPath)
    }

    Write-Step ("Desktop shortcut verified: " + $startPath)
    Write-Step ("Desktop shortcut verified: " + $stopPath)
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
    Write-Host "  Endpoint: http://127.0.0.1:$Port/v3"
    Write-Host "  Model:    $Model"
    Write-Host "  API key:  none"
}

switch ($Action) {
    "doctor"  { Show-Doctor }
    "devices" { Show-SuspectDevices }
    "install" { Install-Ovms; Show-Doctor }
    "model"   { Prepare-Model }
    "repair-tokenizer" { Repair-DefaultTokenizer }
    "repair-file" { Repair-ModelLfsFile $RepairFile }
    "finalize-model" { Finalize-LocalModel }
    "start"   { Start-Ovms }
    "test"    { Test-NpuChat }
    "stop"    { Stop-Ovms }
    "launch"  { Launch-PebrelWithNpu }
    "shortcut" { Install-PebrelNpuShortcuts }
    "setup"   {
        Install-Ovms
        Prepare-Model
        Start-Ovms
        Test-NpuChat
        Show-Doctor
    }
}
