# ============================================================
# mochi-live-kit 一键启动脚本（Windows PowerShell 5.1+ / PowerShell 7）
#
# 功能：
#   1. 检测 docker compose 或 docker-compose（二者存在哪个用哪个）
#   2. 缺少真实配置时自动从 *.sample 复制
#   3. 检测到占位符时自动生成 API key/secret 与 TURN 密码，同步写入三处配置
#   4. 自动探测公网 IP 填入 coturn external-ip
#   5. docker compose up -d
#   6. 打印 LiveKit 日志
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\start.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

function Log($m)  { Write-Host "[start] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[warn] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[error] $m" -ForegroundColor Red; exit 1 }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Utf8($path) { return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
function Write-Utf8($path, $text) { [System.IO.File]::WriteAllText($path, $text, $utf8NoBom) }

# ---------- 1. 检测 compose 命令 ----------
$DC = @()
docker compose version *> $null
if ($LASTEXITCODE -eq 0) {
  $DC = @('docker', 'compose')
} elseif (Get-Command docker-compose -ErrorAction SilentlyContinue) {
  $DC = @('docker-compose')
} else {
  Die '未找到 docker compose / docker-compose，请先安装 Docker 与 Compose'
}
Log ("使用: " + ($DC -join ' '))

# 用插件（docker compose）还是独立二进制（docker-compose）
$usePlugin = ($DC.Length -gt 1)

# ---------- 2. 复制模板 ----------
$pairs = @(
  @{ Real = 'livekit.yaml';     Sample = 'livekit.yaml.sample' },
  @{ Real = 'ingress.yaml';     Sample = 'ingress.yaml.sample' },
  @{ Real = 'turnserver.conf';  Sample = 'turnserver.conf.sample' },
  @{ Real = 'Caddyfile';        Sample = 'Caddyfile.sample' }
)
foreach ($p in $pairs) {
  if (-not (Test-Path -LiteralPath $p.Real)) {
    if (-not (Test-Path -LiteralPath $p.Sample)) { Die "缺少模板文件 $($p.Sample)" }
    Copy-Item -LiteralPath $p.Sample -Destination $p.Real
    Log "生成 $($p.Real)（来自 $($p.Sample)）"
  }
}

# ---------- 3. 自动生成 key / secret / TURN 密码 ----------
function New-Hex([int]$bytes) {
  $b = New-Object byte[] $bytes
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

if ((Read-Utf8 'livekit.yaml').Contains('CHANGE_ME_LIVEKIT_KEY')) {
  $key = New-Hex 8                       # 16 位 hex
  $secret = New-Hex 24                   # 48 位 hex
  $turnPass = New-Hex 24

  # livekit.yaml：keys 与 turn_servers 凭据
  $l = Read-Utf8 'livekit.yaml'
  $l = $l.Replace('CHANGE_ME_LIVEKIT_KEY: CHANGE_ME_LIVEKIT_SECRET', "$($key): $($secret)")
  $l = $l.Replace('CHANGE_ME_COTURN_PASSWORD', $turnPass)
  Write-Utf8 'livekit.yaml' $l

  # ingress.yaml：api_key / api_secret
  $i = Read-Utf8 'ingress.yaml'
  $i = $i.Replace('CHANGE_ME_LIVEKIT_KEY', $key).Replace('CHANGE_ME_LIVEKIT_SECRET', $secret)
  Write-Utf8 'ingress.yaml' $i

  # turnserver.conf：coturn 长期凭据
  $t = Read-Utf8 'turnserver.conf'
  $t = $t.Replace('CHANGE_ME_COTURN_PASSWORD', $turnPass)
  Write-Utf8 'turnserver.conf' $t

  Log '已生成新密钥（三处配置已同步）'
  Write-Host "  LIVEKIT_API_KEY    = $key"
  Write-Host "  LIVEKIT_API_SECRET = $secret"
  Write-Host "  TURN 密码          = $turnPass"
  Warn '请保存以上密钥（也已在本地配置文件中），不要提交到公开仓库'
} else {
  Log 'livekit.yaml 已有真实密钥，跳过生成'
}

# ---------- 4. 自动填公网 IP（coturn external-ip） ----------
if ((Read-Utf8 'turnserver.conf').Contains('YOUR_PUBLIC_IP')) {
  $pubIp = $null
  foreach ($u in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://ipinfo.io/ip')) {
    try {
      $pubIp = (Invoke-RestMethod -Uri $u -TimeoutSec 5).ToString().Trim()
      if ($pubIp) { break }
    } catch { }
  }
  if ($pubIp) {
    $t = Read-Utf8 'turnserver.conf'
    $t = $t.Replace('YOUR_PUBLIC_IP', $pubIp)
    Write-Utf8 'turnserver.conf' $t
    Log "coturn external-ip 自动填为 $pubIp"
  } else {
    Warn '未能探测公网 IP，请手动修改 turnserver.conf 的 external-ip'
  }
}

# ---------- 5. 启动 ----------
Log 'docker compose up -d ...'
if ($usePlugin) { docker compose up -d } else { docker-compose up -d }
if ($LASTEXITCODE -ne 0) { Die 'docker compose up -d 失败' }

# ---------- 6. 状态 + LiveKit 日志 ----------
Start-Sleep -Seconds 4
if ($usePlugin) { docker compose ps 2>$null | Out-Host } else { docker-compose ps 2>$null | Out-Host }

Log 'LiveKit 最近日志：'
if ($usePlugin) { docker compose logs --tail=80 livekit-3fc8d7 2>$null | Out-Host } else { docker-compose logs --tail=80 livekit-3fc8d7 2>$null | Out-Host }
Write-Host ''
Log ("完成。持续跟踪日志: " + ($DC -join ' ') + ' logs -f livekit-3fc8d7')
