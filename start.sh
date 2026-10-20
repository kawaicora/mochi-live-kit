#!/usr/bin/env bash
# ============================================================
# mochi-live-kit 一键启动脚本（Linux / macOS）
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
#   chmod +x start.sh && ./start.sh
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

log()  { printf '\033[1;34m[start]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. 检测 compose 命令 ----------
DC=()
if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  die "未找到 docker compose / docker-compose，请先安装 Docker 与 Compose"
fi
log "使用: ${DC[*]}"

# ---------- 2. 复制模板 ----------
copy_sample() {
  local real="$1" sample="$2"
  if [ ! -f "$real" ]; then
    [ -f "$sample" ] || die "缺少模板文件 $sample"
    cp "$sample" "$real"
    log "生成 $real（来自 $sample）"
  fi
}
copy_sample livekit.yaml livekit.yaml.sample
copy_sample ingress.yaml ingress.yaml.sample
copy_sample turnserver.conf turnserver.conf.sample
copy_sample Caddyfile Caddyfile.sample

# ---------- 3. 自动生成 key / secret / TURN 密码 ----------
gen_hex() {
  # 输出 n 字节的 hex 字符串（2n 个字符）
  openssl rand -hex "$1" 2>/dev/null && return 0
  head -c "$1" /dev/urandom | od -An -vtx1 | tr -d ' \n'
}

gen_key() {
  # LiveKit API key：16 位 hex 字母数字
  openssl rand -hex 8 2>/dev/null && return 0
  head -c 8 /dev/urandom | od -An -vtx1 | tr -d ' \n'
}

if grep -q 'CHANGE_ME_LIVEKIT_KEY' livekit.yaml 2>/dev/null; then
  KEY="$(gen_key)"
  SECRET="$(gen_hex 24)"
  TURN_PASS="$(gen_hex 24)"

  # livekit.yaml：keys 与 turn_servers 凭据
  sed -i "s/CHANGE_ME_LIVEKIT_KEY: CHANGE_ME_LIVEKIT_SECRET/${KEY}: ${SECRET}/" livekit.yaml
  sed -i "s/CHANGE_ME_COTURN_PASSWORD/${TURN_PASS}/g" livekit.yaml
  # ingress.yaml：api_key / api_secret
  sed -i "s/CHANGE_ME_LIVEKIT_KEY/${KEY}/" ingress.yaml
  sed -i "s/CHANGE_ME_LIVEKIT_SECRET/${SECRET}/" ingress.yaml
  # turnserver.conf：coturn 长期凭据
  sed -i "s/CHANGE_ME_COTURN_PASSWORD/${TURN_PASS}/g" turnserver.conf

  log "已生成新密钥（三处配置已同步）"
  echo "  LIVEKIT_API_KEY    = $KEY"
  echo "  LIVEKIT_API_SECRET = $SECRET"
  echo "  TURN 密码          = $TURN_PASS"
  warn "请保存以上密钥（也已在本地配置文件中），不要提交到公开仓库"
else
  log "livekit.yaml 已有真实密钥，跳过生成"
fi

# ---------- 4. 自动填公网 IP（coturn external-ip） ----------
if grep -q 'YOUR_PUBLIC_IP' turnserver.conf 2>/dev/null; then
  PUBIP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -z "$PUBIP" ] && PUBIP="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [ -z "$PUBIP" ] && PUBIP="$(curl -fsS --max-time 5 https://ipinfo.io/ip 2>/dev/null || true)"
  if [ -n "$PUBIP" ]; then
    sed -i "s/YOUR_PUBLIC_IP/${PUBIP}/" turnserver.conf
    log "coturn external-ip 自动填为 $PUBIP"
  else
    warn "未能探测公网 IP，请手动修改 turnserver.conf 的 external-ip"
  fi
fi

# ---------- 5. 启动 ----------
log "docker compose up -d ..."
"${DC[@]}" up -d

# ---------- 6. 状态 + LiveKit 日志 ----------
sleep 4
"${DC[@]}" ps || true

log "LiveKit 最近日志："
"${DC[@]}" logs --tail=80 livekit-3fc8d7 2>/dev/null || true
echo
log "完成。持续跟踪日志: ${DC[*]} logs -f livekit-3fc8d7"
