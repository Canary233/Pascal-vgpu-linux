<#
.SYNOPSIS
    为 Windows 客户机配置 NVIDIA vGPU 授权令牌（配合 FastAPI-DLS 使用）

.DESCRIPTION
    1) 把 client_configuration_token.tok 复制到 vGPU Licensing 的 ClientConfigToken 目录
    2) 重启 NVDisplay.ContainerLocalSystem 服务
    3) 输出 nvidia-smi 的授权状态

    需要以管理员身份运行。令牌文件可从挂载的 ISO/光驱、共享目录或任意路径获取。

.PARAMETER TokenPath
    令牌文件路径。省略时依次查找：
      - 脚本同目录下的 client_configuration_token.tok
      - 各光驱根目录下的 client_configuration_token.tok

.EXAMPLE
    .\guest-windows.ps1

.EXAMPLE
    .\guest-windows.ps1 -TokenPath D:\client_configuration_token.tok
#>
[CmdletBinding()]
param(
    [string]$TokenPath
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "[!] $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 管理员检查

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error '请以管理员身份运行 PowerShell'
    exit 1
}

# ---------------------------------------------------------------- 找令牌

if (-not $TokenPath) {
    $candidates = @()
    $candidates += Join-Path $PSScriptRoot 'client_configuration_token.tok'
    foreach ($d in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot -eq $null -and $_.Root -match '^[A-Z]:\\$' })) {
        $candidates += Join-Path $d.Root 'client_configuration_token.tok'
    }
    $TokenPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $TokenPath -or -not (Test-Path $TokenPath)) {
    Write-Error ' 未找到 client_configuration_token.tok，请用 -TokenPath 指定'
    exit 1
}
Write-Step "令牌文件：$TokenPath"

# ---------------------------------------------------------------- 目标目录

$targets = @(
    'C:\ProgramData\NVIDIA Corporation\vGPU Licensing\ClientConfigToken',
    'C:\Program Files\NVIDIA Corporation\vGPU Licensing\ClientConfigToken'
)

$written = @()
foreach ($t in $targets) {
    $parent = Split-Path $t -Parent
    if (Test-Path $parent) {
        New-Item -ItemType Directory -Force -Path $t | Out-Null
        $dest = Join-Path $t 'client_configuration_token.tok'
        Copy-Item -Force $TokenPath $dest
        $written += $dest
        Write-Ok "已写入 $dest"
    }
}

if ($written.Count -eq 0) {
    # 两个父目录都不存在 —— 说明驱动还没装
    $fallback = $targets[0]
    New-Item -ItemType Directory -Force -Path $fallback | Out-Null
    $dest = Join-Path $fallback 'client_configuration_token.tok'
    Copy-Item -Force $TokenPath $dest
    $written += $dest
    Write-Warn2 '未找到 NVIDIA vGPU Licensing 目录，已按默认路径创建'
    Write-Warn2 '如果驱动还没安装，请先安装 vGPU Guest Driver，再重新运行本脚本'
    Write-Ok "已写入 $dest"
}

# ---------------------------------------------------------------- 重启服务

Write-Step '重启 NVDisplay.ContainerLocalSystem'
try {
    Restart-Service -Name 'NVDisplay.ContainerLocalSystem' -Force
    Write-Ok '服务已重启'
} catch {
    Write-Warn2 "重启服务失败：$($_.Exception.Message)"
    Write-Warn2 '若驱动尚未安装，先安装驱动并重启系统，再运行本脚本'
}

# ---------------------------------------------------------------- 验证

Start-Sleep -Seconds 8

$smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
if (Test-Path $smi) {
    Write-Step '授权状态：'
    & $smi -q | Select-String -Pattern 'License|vGPU Software Licensed Product' | ForEach-Object { $_.Line.Trim() }
} else {
    Write-Warn2 'nvidia-smi 不存在，说明 vGPU 驱动尚未安装'
}

Write-Host ''
Write-Ok '完成'
