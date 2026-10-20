# mochi-live-kit — LiveKit SFU + Ingress 自托管部署

基于 LiveKit 的自托管实时音视频栈（Docker 单机），信号入口域名 **`xxx.xxxx.org`**。
包含：**SFU**（WebRTC 转发）+ **Ingress**（OBS 推流 RTMP/WHIP）+ **coturn**（TURN/STUN）+ **redis**。

## 架构

```
 客户端 (wss://xxx.xxxx.org)
        │ 443/tcp (TLS/WSS, 1Panel 或 Caddy 反代)
┌─────────────────────────────────────────────────────────┐
│  全部 host 网络（各服务直占宿主端口，经 127.0.0.1 互通）    │
│  livekit-server  7880 信号/API │ 7881 ICE-TCP │ 20000-25000 媒体 │
│  ingress       1935 RTMP │ 8080 WHIP-HTTP │ 7885/udp WHIP媒体 │
│  redis           127.0.0.1:6379                          │
│  coturn          3478 TURN/STUN │ 30000-60000 中继        │
└─────────────────────────────────────────────────────────┘
        ▲ RTMP / WHIP 推流（OBS）进入房间
        ▼ 客户端 WebRTC 拉流观看
```

- **全部服务使用 host 网络**：SFU 媒体 UDP 免端口映射、性能最好；livekit 经 `127.0.0.1:6379`
  访问 redis（host 下不走服务名 DNS）。coturn、ingress 同宿主栈互通。
- **Ingress**：OBS 直推 **RTMP**（`1935/tcp`）或 **WHIP**（`8080/tcp` + `7885/udp`），
  WHIP 会话要求 host 网络，转码后发布进 LiveKit 房间。
- **反代**：默认用 **1Panel**，把 `xxx.xxxx.org` 反代到 `127.0.0.1:7880`（开 WebSocket），
  并额外加 `/whip` 反代到 `127.0.0.1:8080`。`caddy` 服务已注释，需要时取消注释即可。
- **数据统一 bind mount** 到 `./data/<name>-data`，随目录整体迁移，无命名卷。

## 前置条件

- 公网可达的 Linux 服务器，Docker + Docker Compose v2。
- 域名 DNS **A 记录**均指向本机公网 IP：
  - `xxx.xxxx.org` → 信号 / WHIP 入口
  - `app.kawaimoe.org` → TURN/STUN（coturn），与前端 iceServers 一致

## 部署步骤

```bash
# 1. 密钥与凭据直接写在配置文件里（配置文件不会展开 ${VAR}，用环境变量是无效的）
#    - livekit.yaml 的 keys: 段
#    - livekit.yaml 的 rtc.turn_servers: 段（与 turnserver.conf 的 user= 一致）
#    - ingress.yaml 的 api_key / api_secret
#    换密钥：把这三处一起改掉并 docker compose up -d --force-recreate。

# 2. 启动
docker compose up -d

# 3. 反向代理（默认 1Panel）
#    站点 xxx.xxxx.org 反代到 http://127.0.0.1:7880，开 WebSocket，配 SSL；
#    再新增 /whip 位置反代到 http://127.0.0.1:8080（OBS WHIP 推流）。
#    若改用 Caddy：取消 docker-compose.yaml 中 caddy 段注释后重启。
```

## 防火墙放行端口

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| 80 / 443 | tcp | 证书申请 / HTTPS / WSS 信号 |
| 7881 | tcp | WebRTC over TCP 回退 |
| 20000-25000 | udp | WebRTC 媒体流（避开 coturn 30000-60000） |
| **1935** | tcp | **RTMP 推流（OBS）** |
| **8080** | tcp | **WHIP HTTP 接口（OBS）** |
| **7885** | udp | **WHIP 媒体（OBS）** |
| 3478 | udp+tcp | TURN/STUN（coturn） |

> 7880 内部信号端口，无需对公网开放（经反代）；8080 可只放行回环、经 443 `/whip` 反代。

## OBS 推流接入（RTMP / WHIP）

用服务端 SDK / `livekit-cli` 调用 **CreateIngress**，拿回推流地址 + stream key，再填进 OBS。

```bash
# 创建 RTMP 推流入口（返回 url + stream_key）
npx livekit-cli ingress create \
  --api-key "$LIVEKIT_API_KEY" --api-secret "$LIVEKIT_API_SECRET" \
  --url ws://127.0.0.1:7880 \
  --room myroom --identity obs \
  --input-type RTMP

# 创建 WHIP 推流入口（input-type 改 WHIP 即可）
npx livekit-cli ingress create \
  --api-key "$LIVEKIT_API_KEY" --api-secret "$LIVEKIT_API_SECRET" \
  --url ws://127.0.0.1:7880 \
  --room myroom --identity obs \
  --input-type WHIP
```

**OBS 填写**：

| 方式 | OBS 配置 |
| --- | --- |
| RTMP | 设置 → 推流 → 服务“自定义”：`rtmp://xxx.xxxx.org/live/<stream_key>` |
| WHIP（推荐，低延迟） | 输出 → WHIP，URL：`https://xxx.xxxx.org/whip/<stream_key>`（OBS 28.1+ 内置） |

推流后画面即作为参与者发布进 `myroom`，WebRTC 客户端加入同房间即可观看。

> 注意：Ingress 转码（尤其 RTMP）较耗资源，官方建议每实例 **≥4 CPU / 4 GB**。

## 客户端接入

- **连接地址**：`wss://xxx.xxxx.org`
- **STUN**：`livekit.yaml` 已配置 `rtc.stun_servers`（Google / Cloudflare），客户端可以打 STUN
  走反射候选；能直连就直连（P2P 直连），直连失败才回退到 TURN 中继。
- **内网直连**：`rtc.advertise_internal_ip: true` 会同时广告内网与公网候选，
  同网段/内网客户端可直接连服务器内网 IP（host 候选），不必绕公网。
- **ICE**：iceServers 用 `app.kawaimoe.org:3478` 的 TURN/STUN（LiveKit 会自动下发）。
- **鉴权**：`livekit.yaml` 的 `keys:` 签发 JWT 后 `Room.connect(url, token)`

## 验证

```bash
curl https://xxx.xxxx.org/            # 443 通
ss -tlnp | grep -E '7880|7881|1935|8080'   # 本机端口在监听
docker compose ps                          # 各服务 running
```

## 常见问题

- **证书拿不到**：A 记录未指向本机，或 80/443 未放行。
- **呼叫不通（黑屏/无声）**：多为 20000-25000/udp 未放行，或 coturn `external-ip` 与本机公网 IP 不一致；内网客户端可用 `rtc.advertise_internal_ip` 直连内网地址。
- **OBS 推流失败**：确认 1935/8080/7885 已放行；WHIP 走 443 时 1Panel 需加 `/whip` 反代到 8080。
- **升级版本**：改 `docker-compose.yaml` 里 image 版本后 `docker compose up -d`（建议固定版本，如 `v1.x.y`）。

## 目录结构

```
mochi-live-kit/
├── docker-compose.yaml   # livekit + redis + coturn + ingress（+ caddy 反代，默认注释）
├── livekit.yaml.sample   # 模板：SFU 配置（keys / STUN / TURN / ingress 基址；真实文件被 .gitignore 忽略）
├── ingress.yaml.sample   # 模板：Ingress 配置（RTMP/WHIP，含 api_key/api_secret/ws_url）
├── turnserver.conf.sample# 模板：coturn 配置（external-ip / 长期凭据）
├── Caddyfile.sample      # 模板：域名 TLS 反代（可选，默认用 1Panel）
├── redis.conf            # Redis 配置
└── data/                 # 持久化数据（bind mount，随目录整体迁移）
    ├── redis-data/
    ├── caddy-data/       #（启用 Caddy 时生成）
    └── caddy-config/     #（启用 Caddy 时生成）
```

> 部署前：`cp livekit.yaml.sample livekit.yaml`、`cp ingress.yaml.sample ingress.yaml`、
> `cp turnserver.conf.sample turnserver.conf`、`cp Caddyfile.sample Caddyfile`，
> 再把里面的 `CHANGE_ME_*` / `YOUR_PUBLIC_IP` 替换为真实值。这四个真实文件已在
> `.gitignore` 中忽略，不会入库。（也可以直接运行 `./start.sh` 或 `.\start.ps1`，
> 脚本会自动复制模板并生成密钥。）
