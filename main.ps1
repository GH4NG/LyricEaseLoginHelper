class UwpRegistryKeyEntry {
    [string] $Path
    [string] $Name
    [object] $Value
    [string] $Type
}

function Invoke-RegCommand {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'reg.exe'
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout.Trim()
        StdErr   = $stderr.Trim()
    }
}

function ConvertTo-HexBytes {
    param(
        [Parameter(Mandatory)] [object] $Value,
        [Parameter(Mandatory)] [string] $Type
    )

    switch ($Type) {
        # bool (1 byte)
        '5f5e10b' { [byte]([bool]$Value) }
        # string (N bytes, Unicode + null)
        '5f5e10c' {
            ([System.Text.Encoding]::Unicode.GetBytes([string]$Value)) + 0x00, 0x00
        }
        # int32 (4 bytes)
        '5f5e104' { [BitConverter]::GetBytes([int32] $Value) }
        # uint32 (4 bytes)
        '5f5e105' { [BitConverter]::GetBytes([uint32]$Value) }
        # int64 (8 bytes)
        '5f5e106' { [BitConverter]::GetBytes([int64] $Value) }
        # uint64 (8 bytes)
        '5f5e107' { [BitConverter]::GetBytes([uint64]$Value) }
        # double (8 bytes big-endian)
        '5f5e109' {
            $leBytes = [BitConverter]::GetBytes([double]$Value)
            $beBytes = @(0, 0, 0, 0, 0, 0, 0, 0)
            $start = 8 - $leBytes.Length
            for ($i = 0; $i -lt $leBytes.Length; $i++) {
                $beBytes[$start + $i] = $leBytes[$i]
            }
            $beBytes
        }
        # GUID (16 bytes)
        '5f5e110' {
            if ($Value -is [guid]) { $Value.ToByteArray() }
            elseif ($Value -is [byte[]] -and $Value.Length -eq 16) { $Value }
            else { throw "GUID 类型的值无效，必须是 [guid] 类型或 16 字节数组" }
        }

        default { throw "不支持的数据类型: $Type" }
    }
}

function Set-UwpAppRegistryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [UwpRegistryKeyEntry] $InputObject,
        [Parameter(Mandatory)] [string] $FilePath
    )

    begin {
        $AppSettingsRegPath = 'HKEY_USERS\APP_SETTINGS'
        $RegContent = "Windows Registry Editor Version 5.00`n"
    }

    process {
        $ValueBytes = ConvertTo-HexBytes -Value $InputObject.Value -Type $InputObject.Type
        $ValueHex = ($ValueBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ','

        $TimestampBytes = [BitConverter]::GetBytes((Get-Date).ToFileTime())
        $TimestampHex = ($TimestampBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ','

        $RegKey = if ($InputObject.Path) { $InputObject.Path } else { 'LocalState' }

        $RegContent += "`n[$AppSettingsRegPath\$RegKey]
        `"$($InputObject.Name)`"=hex($($InputObject.Type)):$ValueHex,$TimestampHex`n"
    }

    end {
        $TempRegFile = Join-Path $env:TEMP ("LyricEaseSettings_{0}.reg" -f ([guid]::NewGuid().ToString('N')))
        $RegContent | Out-File -FilePath $TempRegFile -Encoding Unicode

        $queryResult = Invoke-RegCommand -Arguments @('QUERY', $AppSettingsRegPath)
        if ($queryResult.ExitCode -eq 0) {
            Invoke-RegCommand -Arguments @('UNLOAD', $AppSettingsRegPath) | Out-Null
        }

        $loaded = $false
        try {
            $loadResult = Invoke-RegCommand -Arguments @('LOAD', $AppSettingsRegPath, $FilePath)
            if ($loadResult.ExitCode -ne 0) {
                throw "reg.exe LOAD 失败（ExitCode=$($loadResult.ExitCode)）：$($loadResult.StdErr) $($loadResult.StdOut)"
            }
            $loaded = $true

            $importResult = Invoke-RegCommand -Arguments @('IMPORT', $TempRegFile)
            if ($importResult.ExitCode -ne 0) {
                throw "reg.exe IMPORT 失败（ExitCode=$($importResult.ExitCode)）：$($importResult.StdErr) $($importResult.StdOut)"
            }
        }
        finally {
            if ($loaded) {
                $unloadResult = Invoke-RegCommand -Arguments @('UNLOAD', $AppSettingsRegPath)
                if ($unloadResult.ExitCode -ne 0) {
                    Write-Warning "reg.exe UNLOAD 失败（ExitCode=$($unloadResult.ExitCode)）：$($unloadResult.StdErr) $($unloadResult.StdOut)"
                }
            }

            Remove-Item -LiteralPath $TempRegFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Login-LyricEase {
    param(
        [Parameter(Mandatory)] [string] $ScriptDir
    )

    $pkg = Get-AppxPackage -Name '17588BrandonWong.LyricEase' -ErrorAction SilentlyContinue
    if (-not $pkg) {
        $pkg = Install-LyricEase -ScriptDir $ScriptDir
    }

    $packageDataDir = Join-Path $env:LOCALAPPDATA ("Packages\{0}" -f $pkg.PackageFamilyName)
    if (-not (Test-Path -LiteralPath $packageDataDir)) {
        throw "找不到应用数据目录：$packageDataDir"
    }

    Write-Host '步骤 1/3: 正在读取 Cookie 配置文件...' -ForegroundColor Cyan
    $cookieJsonPath = Join-Path $ScriptDir 'cookies.json'
    if (-not (Test-Path -LiteralPath $cookieJsonPath)) {
        throw '找不到 cookies.json 文件。'
    }

    $json = Get-Content -Raw -Path $cookieJsonPath | ConvertFrom-Json
    $expires = '2099-12-30T23:59:59+08:00'
    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffffffK')

    $cookieObjects = foreach ($p in $json.PSObject.Properties) {
        [PSCustomObject]@{
            IsQuotedVersion = $false
            IsQuotedDomain  = $false
            Comment         = ''
            CommentUri      = $null
            HttpOnly        = $false
            Discard         = $false
            Domain          = ''
            Expired         = $false
            Expires         = $expires
            Name            = $p.Name
            Path            = '/'
            Port            = ''
            Secure          = $false
            TimeStamp       = $timestamp
            Value           = $p.Value
            Variant         = 1
            Version         = 0
        }
    }

    $cookieFile = Join-Path $packageDataDir 'LocalState\cookie'
    $cookieDir = Split-Path -Parent $cookieFile
    if (-not (Test-Path -LiteralPath $cookieDir)) {
        New-Item -ItemType Directory -Path $cookieDir -Force | Out-Null
    }

    $cookieObjects | ConvertTo-Json -Depth 10 | Out-File -FilePath $cookieFile -Encoding UTF8
    Write-Host "Cookie 已保存到: $cookieFile" -ForegroundColor Green

    Write-Host '步骤 2/3: 正在验证用户身份并获取用户信息...' -ForegroundColor Cyan
    $musicU = $json.MUSIC_U
    if ([string]::IsNullOrWhiteSpace($musicU)) { throw 'cookies.json 中缺少 MUSIC_U 字段' }

    $url = "https://ncm.gh4ng.top/login/status?cookie=MUSIC_U=$musicU"
    $response = Invoke-RestMethod -Uri $url -Method Get
    if (-not ($response.data.account.id -and $response.data.profile.nickname)) {
        throw 'API 返回的用户数据不完整，缺少账户 ID 或昵称信息'
    }

    $userData = [PSCustomObject]@{
        AccountId = [uint64]$response.data.account.id
        Nickname  = [string]$response.data.profile.nickname
        AvatarUrl = [string]$response.data.profile.avatarUrl
        IsVip     = [bool]($response.data.profile.vipType -gt 0)
    }

    Write-Host '用户信息获取成功!' -ForegroundColor Green
    Write-Host "用户: $($userData.Nickname) (ID: $($userData.AccountId))" -ForegroundColor White

    Write-Host '步骤 3/3: 正在配置 LyricEase 应用设置...' -ForegroundColor Cyan

    $settingsDat = Join-Path $packageDataDir 'Settings\settings.dat'
    if (-not (Test-Path -LiteralPath $settingsDat)) {
        throw "找不到 settings.dat：$settingsDat"
    }

    Write-Host '正在停止 LyricEase 进程...' -ForegroundColor Yellow
    Stop-Process -Name 'LyricEase' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800

    $udid = [guid]::NewGuid()

    $LyricEaseSettings = @(
        [UwpRegistryKeyEntry]@{ Path = 'LocalState'; Name = 'AppCenterInstallId'; Value = $udid; Type = '5f5e110' },
        [UwpRegistryKeyEntry]@{ Path = 'LocalState'; Name = 'IsFirstRun'; Value = 'True'; Type = '5f5e10c' },
        [UwpRegistryKeyEntry]@{ Path = 'LocalState'; Name = 'currentVersion'; Value = '0.14.153.0'; Type = '5f5e10c' },
        [UwpRegistryKeyEntry]@{ Path = 'LocalState'; Name = 'FirstUseTime'; Value = '134023048624698432'; Type = '5f5e10c' },
        [UwpRegistryKeyEntry]@{ Path = 'LocalState'; Name = 'FirstVersionInstalled'; Value = '0.14.153.0'; Type = '5f5e10c' },

        [UwpRegistryKeyEntry]@{ Path = 'LocalState\DoxPlayerSettings'; Name = 'Volume'; Value = 1; Type = '5f5e109' },

        [UwpRegistryKeyEntry]@{ Path = 'LocalState\Networking'; Name = 'IsHttpFallback'; Value = $false; Type = '5f5e10b' },
        [UwpRegistryKeyEntry]@{ Path = 'LocalState\Networking'; Name = 'ProxyMode'; Value = 0; Type = '5f5e104' },

        [UwpRegistryKeyEntry]@{ Path = 'LocalState\Playback'; Name = 'LyricsFontSize'; Value = -1; Type = '5f5e109' },

        [UwpRegistryKeyEntry]@{ Path = 'LocalState\User'; Name = 'LogInMode'; Value = 2; Type = '5f5e104' },
        [UwpRegistryKeyEntry]@{ Path = 'LocalState\User'; Name = 'UserNickname'; Value = $userData.Nickname; Type = '5f5e10c' },
        [UwpRegistryKeyEntry]@{ Path = 'LocalState\User'; Name = 'UserID'; Value = $userData.AccountId; Type = '5f5e107' },
        [UwpRegistryKeyEntry]@{ Path = 'LocalState\User'; Name = 'UserAvatarUrl'; Value = $userData.AvatarUrl; Type = '5f5e10c' },
        [UwpRegistryKeyEntry]@{ Path = 'LocalState\User'; Name = 'IsUserVIP'; Value = $userData.IsVip; Type = '5f5e10b' }
    )

    $LyricEaseSettings | Set-UwpAppRegistryEntry -FilePath $settingsDat

    Write-Host 'LyricEase 设置配置成功!' -ForegroundColor Green
    Write-Host '现在可以启动 LyricEase 应用' -ForegroundColor Cyan
}

function Install-LyricEase {
    param(
        [Parameter(Mandatory)] [string] $ScriptDir
    )

    Write-Host '检测到 LyricEase 未安装，开始自动安装...' -ForegroundColor Yellow

    $packageFile = Get-ChildItem -LiteralPath $ScriptDir -Filter '*.msix*' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $packageFile) { throw '未找到 LyricEase 安装包（*.msixbundle / *.msix）。' }

    $certFile = Get-ChildItem -LiteralPath $ScriptDir -Filter '*.cer' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $certFile) { throw '未找到证书文件 (*.cer)。' }

    Write-Host "使用安装包: $($packageFile.Name)" -ForegroundColor Cyan
    Write-Host "使用证书: $($certFile.Name)" -ForegroundColor Cyan

    $originalDate = Get-Date
    $w32time = Get-Service -Name 'w32time' -ErrorAction SilentlyContinue
    $w32timeWasRunning = $w32time -and $w32time.Status -eq 'Running'
    if ($w32timeWasRunning) {
        Write-Host '正在停止 Windows 时间服务...' -ForegroundColor Yellow
        Stop-Service -Name 'w32time' -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $targetDate = Get-Date '2024-10-10T12:00:00'
    Write-Host "正在临时设置系统时间: $targetDate" -ForegroundColor Yellow
    try { Set-Date -Date $targetDate | Out-Null } catch { throw "设置系统时间失败：$($_.Exception.Message)" }

    try {
        Write-Host '正在导入证书到 LocalMachine\TrustedPeople...' -ForegroundColor Yellow
        $cert = Import-Certificate -FilePath $certFile.FullName -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' -ErrorAction Stop
        Write-Host "证书导入成功: $($cert.Subject)" -ForegroundColor Green

        Write-Host '正在安装应用...' -ForegroundColor Yellow
        Add-AppxPackage -Path $packageFile.FullName -ForceApplicationShutdown -ForceUpdateFromAnyVersion | Out-Null
        Write-Host '应用安装完成。' -ForegroundColor Green
    }
    finally {
        Write-Host "正在还原系统时间为：$originalDate" -ForegroundColor Yellow
        try { Set-Date -Date $originalDate | Out-Null } catch { Write-Warning "系统时间还原失败：$($_.Exception.Message)" }

        if ($w32timeWasRunning) {
            Write-Host '正在恢复 Windows 时间服务...' -ForegroundColor Yellow
            Start-Service -Name 'w32time' -ErrorAction SilentlyContinue | Out-Null
            try { w32tm /resync | Out-Null } catch { }
        }
    }

    $pkg = Get-AppxPackage -Name '17588BrandonWong.LyricEase' -ErrorAction SilentlyContinue
    if (-not $pkg) {
        throw '自动安装已执行，但仍未检测到 LyricEase 已安装。'
    }
    return $pkg
}

function main {
    $scriptDir = if ($PSScriptRoot) {
        $PSScriptRoot
    }
    elseif ($PSCommandPath) {
        Split-Path -Parent $PSCommandPath
    }
    else {
        (Get-Location).Path
    }

    Set-Location -Path $scriptDir

    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '权限不足：请使用以管理员身份运行的 PowerShell 再执行该脚本。'
    }

    try {
        Login-LyricEase -ScriptDir $scriptDir
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

main