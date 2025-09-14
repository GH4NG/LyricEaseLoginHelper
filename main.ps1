#=================================================================================================================
#  LyricEase 自动登录配置工具
#
#  Copyright (c) 2025 LyricEase Login Helper
#  Licensed under MIT License
#=================================================================================================================

#===========================================
# 检查管理员权限
#===========================================
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Error "权限不足：此脚本需要管理员权限。"
    exit 1
}

#===========================================
# UWP 注册表操作类和函数
#===========================================
class UwpRegistryKeyEntry {
    [string] $Path
    [string] $Name
    [object] $Value
    [string] $Type
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
        $Value = ($ValueBytes | ForEach-Object { "{0:X2}" -f $_ }) -join ','

        $RegKey = if ($InputObject.Path) { $InputObject.Path } else { 'LocalState' }

        $RegContent += "`n[$AppSettingsRegPath\$RegKey]
`"$($InputObject.Name)`"=hex($($InputObject.Type)):$Value,00,00,00,00,00,00,00,00`n"
    }

    end {
        $TempRegFile = "$env:TEMP\LyricEaseSettings.reg"
        $RegContent | Out-File -FilePath $TempRegFile -Encoding ASCII

        reg.exe LOAD   $AppSettingsRegPath $FilePath | Out-Null
        reg.exe IMPORT $TempRegFile 2>&1             | Out-Null
        reg.exe UNLOAD $AppSettingsRegPath           | Out-Null

        Remove-Item -Path $TempRegFile -Force
    }
}

function Get-LyricEasePackagePath {
    $PackagePath = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory |
    Where-Object { $_.Name -like "*LyricEase*" } |
    Select-Object -First 1

    if (-not $PackagePath) {
        throw "应用查找失败：在 $env:LOCALAPPDATA\Packages 中找不到 LyricEase 应用包。请确认 LyricEase 已正确安装。"
    }
    return $PackagePath.FullName
}

#===========================================
# 步骤 1: 读取 cookies.json
#===========================================
Write-Host "步骤 1/3: 正在读取 Cookie 配置文件..." -ForegroundColor Cyan

try {
    $json = Get-Content -Raw -Path ".\cookies.json" | ConvertFrom-Json
    $expires = "2099-12-30T23:59:59+08:00"
    $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffffffK")

    $result = foreach ($p in $json.PSObject.Properties) {
        [PSCustomObject]@{
            IsQuotedVersion = $false
            IsQuotedDomain  = $false
            Comment         = ""
            CommentUri      = $null
            HttpOnly        = $false
            Discard         = $false
            Domain          = ""
            Expired         = $false
            Expires         = $expires
            Name            = $p.Name
            Path            = "/"
            Port            = ""
            Secure          = $false
            TimeStamp       = $timestamp
            Value           = $p.Value
            Variant         = 1
            Version         = 0
        }
    }

    $PackagePath = Get-LyricEasePackagePath
    $cookieFile = Join-Path $PackagePath "LocalState\cookie"

    $result | ConvertTo-Json -Depth 10 | Out-File -FilePath $cookieFile -Encoding UTF8
    Write-Host "Cookie 已保存到: $cookieFile" -ForegroundColor Green
}
catch {
    Write-Error "Cookie 文件处理失败: $($_.Exception.Message)"
    exit 1
}

#===========================================
# 步骤 2: 调用 API 获取用户信息
#===========================================
Write-Host "步骤 2/3: 正在验证用户身份并获取用户信息..." -ForegroundColor Cyan

try {
    $musicU = $json.MUSIC_U
    $url = "https://api-enhanced-gh4ng.vercel.app/login/status?cookie=MUSIC_U=$musicU"
    $response = Invoke-RestMethod -Uri $url -Method Get

    if (-not ($response.data.account.id -and $response.data.profile.nickname)) {
        throw "API 返回的用户数据不完整，缺少账户 ID 或昵称信息"
    }

    $userData = @{
        AccountId = $response.data.account.id
        Nickname  = $response.data.profile.nickname
        AvatarUrl = $response.data.profile.avatarUrl
        VipType   = $response.data.profile.vipType
        IsVip     = $response.data.profile.vipType -gt 0
    }

    Write-Host "用户信息获取成功!" -ForegroundColor Green
    Write-Host "用户: $($userData.Nickname) (ID: $($userData.AccountId))" -ForegroundColor White
}
catch {
    Write-Error "API 请求失败: $($_.Exception.Message)"
    exit 1
}

#===========================================
# 步骤 3: 写入用户信息到 settings.dat
#===========================================
Write-Host "步骤 3/3: 正在配置 LyricEase 应用设置..." -ForegroundColor Cyan

try {
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

    $settingsDat = Join-Path $PackagePath "Settings\settings.dat"

    # 停止运行中的 LyricEase 进程
    Stop-Process -Name "LyricEase" -Force -ErrorAction SilentlyContinue

    # 应用配置设置
    $LyricEaseSettings | ForEach-Object {
        Set-UwpAppRegistryEntry -InputObject $_ -FilePath $settingsDat
    }

    Write-Host "LyricEase 设置配置成功!" -ForegroundColor Green
    Write-Host "现在可以启动 LyricEase 应用" -ForegroundColor Cyan
}
catch {
    Write-Error "LyricEase 设置更新失败: $($_.Exception.Message)"
    exit 1
}
