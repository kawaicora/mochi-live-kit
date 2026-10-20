# USE — 使用说明（信令服务器 · API · OBS 推流）

> 适用于本仓库自托管的 LiveKit 实时音视频栈，信号入口域名 **`xxx.xxxx.org`**。
> 组件：SFU（`livekit-server`）、Ingress（RTMP/WHIP 推流）、coturn（TURN/STUN）、redis。
> 本文引用官方文档，结合本部署的实际值编写。

---

## 目录

1. [总览与快速启动](#1-总览与快速启动)
2. [信令服务器（Signaling Server）的使用](#2-信令服务器signaling-server的使用)
3. [OBS 推流配置（Ingress）](#3-obs-推流配置ingress)
4. [Egress（录制 / 转播）简介](#4-egress录制--转播简介)
5. [livekit-cli 命令速查](#5-livekit-cli-命令速查)
6. [参考文档](#6-参考文档)

---

## 1. 总览与快速启动

```
客户端 (wss://xxx.xxxx.org)
   │  443/tcp  TLS/WSS 信令
   ▼
 1Panel/Caddy 反代 ──▶ 127.0.0.1:7880   (livekit-server 信号/API)
                        ├─ 7881/tcp     ICE over TCP
                        ├─ 20000-25000/udp  WebRTC 媒体
                        ├─ redis 127.0.0.1:6379
   OBS ──▶ 1935/tcp RTMP │ 8080/tcp WHIP │ 7885/udp WHIP媒体 ──▶ ingress
   coturn ──▶ 3478/udp+tcp TURN/STUN (app.kawaimoe.org)
```

快速启动：

```bash
# 密钥/凭据直接写在配置里（配置文件不展开 ${VAR}，不要用环境变量占位符）：
#   livekit.yaml → keys: 与 rtc.turn_servers:
#   ingress.yaml → api_key / api_secret / ws_url
docker compose up -d          # 启动 livekit / redis / coturn / ingress
```

- **信令地址**（客户端 SDK 用）：`wss://xxx.xxxx.org`
- **API 服务端**（RoomService / Ingress / Egress）：`https://xxx.xxxx.org`（Twirp/gRPC）
- **OBS 推流地址**：RTMP `rtmp://xxx.xxxx.org/live/<key>` · WHIP `https://xxx.xxxx.org/whip/<key>`

---

## 2. 信令服务器（Signaling Server）的使用

### 2.1 什么是信令

信令（Signaling）是**客户端与 LiveKit 之间的 WebSocket 控制通道**，负责：

- 加入 / 离开房间（JoinRoom）
- 发布 / 订阅媒体轨道的协商（offer/answer）
- 参与者状态同步、静音控制、数据通道（DataChannel）

它**不传输音视频数据**；媒体走 WebRTC（UDP 20000–25000 / TCP 7881），
TURN 走 coturn（3478）。信令只做“握手与控制”。

### 2.2 连接地址与鉴权流程

客户端要加入房间，必须拿到一张**服务端签发的 JWT 访问令牌（token）**：

```
前端 (LiveKit SDK)  →  后端 (Server SDK)  →  LiveKit 信令服务器
   Room.connect(url, token)               验证 token → 授权加入
```

- **URL**：`wss://xxx.xxxx.org`
- **密钥对**：`livekit.yaml` 的 `keys:` 段（服务端 SDK 用它签发 token）
- **令牌有效期**：由后端 `SetValidFor` 控制（如 1 小时），到期需重新签发

> 官方参考：[Generating tokens](https://docs.livekit.io/home/server/generating-tokens/)

### 2.3 生成访问令牌（服务端 SDK）

安装服务端 SDK：`go get github.com/livekit/server-sdk-go/v2`，或 `npm i livekit-server-sdk`、
`pip install livekit-api`。

**Node.js**

```js
import { AccessToken } from 'livekit-server-sdk';

const at = new AccessToken(process.env.LIVEKIT_API_KEY, process.env.LIVEKIT_API_SECRET, {
  identity: 'user-001',
  ttl: '1h',
});
at.addGrant({ roomJoin: true, room: 'my-room' });   // 只允许加入 my-room
const token = await at.toJwt();
```

**Python**

```python
from livekit import api
from datetime import timedelta

token = api.AccessToken(
    api_key, api_secret,
    identity="user-001",
    ttl=timedelta(hours=1),
) .with_grants(api.VideoGrant(room_join=True, room="my-room"))
print(token.to_jwt())
```

**Go**

```go
at := auth.NewAccessToken(apiKey, apiSecret)
grant := &auth.VideoGrant{RoomJoin: true, Room: "my-room"}
token, _ := at.AddGrant(grant).SetIdentity("user-001").SetValidFor(time.Hour).ToJWT()
```

**常用权限（VideoGrant）字段**

| 字段 | 说明 |
| --- | --- |
| `room` / `roomJoin` | 指定房间 / 允许加入房间 |
| `canPublish` | 是否允许发布（推流）音视频轨道 |
| `canSubscribe` | 是否允许订阅（拉流）他人轨道 |
| `canPublishData` | 是否允许发数据通道消息 |
| `roomAdmin` / `roomCreate` / `roomList` | 管理 / 创建 / 列举房间 |
| `roomRecord` | 允许录制该房间 |

### 2.4 客户端 SDK 接入

```js
import { Room } from 'livekit-client';

const room = new Room();
await room.connect('wss://xxx.xxxx.org', token);   // token 由 2.3 获取

// 发布本地音视频（推流）
await room.localParticipant.setCameraEnabled(true);
await room.localParticipant.setMicrophoneEnabled(true);

// 订阅他人轨道
room.on('trackSubscribed', (track) => {
  track.attach(document.body);   // 挂到页面
});
```

官方客户端 SDK：[JavaScript](https://docs.livekit.io/realtime/client/) ·
[iOS](https://docs.livekit.io/ios/) · [Android](https://docs.livekit.io/android/) ·
[Flutter](https://docs.livekit.io/flutter/) · [Unity](https://docs.livekit.io/unity/)

### 2.5 服务端 API（RoomService / Ingress / Egress）

服务端通过 **Twirp / gRPC** 调用（HTTP 端点均在 `https://xxx.xxxx.org`）：

| 服务 | 端点前缀 | 常用方法 |
| --- | --- | --- |
| RoomService | `/twirp/livekit.RoomService/` | `CreateRoom` `ListRooms` `DeleteRoom` `ListParticipants` `MutePublishedTrack` `UpdateParticipant` `UpdateSubscriptions` `SendData` |
| Ingress | `/twirp/livekit.Ingress/` | `CreateIngress` `ListIngress` `UpdateIngress` `DeleteIngress` |
| Egress | `/twirp/livekit.Egress/` | `StartRoomCompositeEgress` `StartTrackCompositeEgress` `StartTrackEgress` `StopEgress` `ListEgress` |

> 官方参考：[Server APIs](https://docs.livekit.io/reference/server/server-apis/) ·
> [LiveKit server 配置（config-sample）](https://github.com/livekit/livekit/blob/master/config-sample.yaml)

**Webhook（可选）**：在 `livekit.yaml` 里配置 `webhook` 段，LiveKit 会把房间事件
（参与者加入/离开、轨道发布等）POST 到你指定的 URL，用 `webhook.api_key` 对应密钥签名。

---

## 3. OBS 推流配置（Ingress）

> 官方参考：[Ingress overview](https://docs.livekit.io/home/ingress/overview/) ·
> [Encoder configuration（OBS）](https://docs.livekit.io/home/ingress/configure-streaming-software/) ·
> [Ingress API](https://docs.livekit.io/reference/other/ingress/api/) ·
> [Self-host Ingress](https://docs.livekit.io/transport/self-hosting/ingress/)

### 3.1 流程总览

```
1. 后端调用 CreateIngress ──▶ 返回 url + stream_key
2. 把 url / stream_key 填进 OBS
3. OBS 开始推流（RTMP 或 WHIP）
4. Ingress 校验 → 转码 → 作为参与者加入房间并发布媒体
5. WebRTC 客户端加入同一房间即可观看
```

`IngressInfo` 里最重要的两个字段（官方定义）：

- **`url`**：推流地址（RTMP `rtmp://…`，WHIP `https://…/whip/…`）
- **`stream_key`**：流密钥（拼接在 URL 后面）

本部署的基址已在 `livekit.yaml` 配置：

```yaml
ingress:
  rtmp_base_url: 'rtmp://xxx.xxxx.org/live'
  whip_base_url: 'https://xxx.xxxx.org/whip'
```

### 3.2 创建 Ingress（CreateIngress）

**输入类型（`input_type` / `IngressInput`）**

| 值 | 名称 | 说明 |
| --- | --- | --- |
| 0 | `RTMP_INPUT` | RTMP 推流（OBS 传统方式） |
| 1 | `WHIP_INPUT` | WHIP 推流（OBS 28.1+，低延迟，本质 WebRTC） |
| 2 | `URL_INPUT` | 从 HTTP/SRT URL 拉流（HLS/MP4/MKV 等） |

**CLI（推荐，最直观）**——先建 `ingress.json`：

```json
{
  "input_type": 1,
  "name": "obs-stream",
  "room_name": "my-room",
  "participant_identity": "obs-1",
  "participant_name": "OBS 直播",
  "enable_transcoding": true
}
```

```bash
export LIVEKIT_URL=https://xxx.xxxx.org
export LIVEKIT_API_KEY=xxx
export LIVEKIT_API_SECRET=xxx
lk ingress create ingress.json
```

返回的 `IngressInfo` 会给出 `url` 与 `stream_key`。

**Node.js（服务端 SDK）**

```js
import { LiveKitAPI, IngressInput } from 'livekit-server-sdk';
const api = new LiveKitAPI();

const info = await api.ingress.createIngress(IngressInput.RTMP_INPUT, {
  name: 'obs-stream',
  roomName: 'my-room',
  participantIdentity: 'obs-1',
  participantName: 'OBS 直播',
  enableTranscoding: true,          // 仅 WHIP 可设为 false（旁路转码）
});
console.log(info.url, info.streamKey);
```

**Python**

```python
from livekit import api
async with api.LiveKitAPI() as lkapi:
    info = await lkapi.ingress.create_ingress(api.CreateIngressRequest(
        input_type=api.IngressInput.WHIP_INPUT,
        name="obs-stream", room_name="my-room",
        participant_identity="obs-1", participant_name="OBS 直播",
        enable_transcoding=True,
    ))
    print(info.url, info.stream_key)
```

### 3.3 OBS 配置 RTMP 推流

1. 拿到 `url`（形如 `rtmp://xxx.xxxx.org/live`）与 `stream_key`。
2. 打开 OBS：**设置 → 推流**。
3. **服务** 选 `自定义…`；**服务器** 填 `rtmp://xxx.xxxx.org/live`；**串流密钥** 填 `stream_key`。
4. 开始直播，画面即发布进 `room_name` 指定房间。

> 官方 OBS 配置步骤：[Encoder configuration（OBS）](https://docs.livekit.io/home/ingress/configure-streaming-software/) ——
> “Settings → Stream → Service = Custom… → Server 填 URL，Stream Key 填 stream_key”。

### 3.4 OBS 配置 WHIP 推流（推荐，低延迟）

WHIP 是 WebRTC 推送协议，延迟接近实时，OBS **28.1+ 内置支持**，无需插件。

1. 创建 `input_type: 1`（WHIP）的 Ingress，拿到 `url` 形如 `https://xxx.xxxx.org/whip/<stream_key>`。
2. OBS：**输出 → WHIP**，在 **WHIP URL** 填入上面的地址。
3. 开始推流。

> 注意：WHIP 需走 443 反代 `/whip` → `127.0.0.1:8080`（1Panel 需新增 `/whip` 位置反代），
> 并放行 UDP `7885`。WHIP 的 `enable_transcoding` 可设为 `false`（旁路，几乎不占 CPU）。

### 3.5 转码与编码预设

`enable_transcoding` 为 `true` 时，Ingress 会转码输入以兼容各客户端。视频有预设：

| 预设 | 说明 |
| --- | --- |
| `H264_1080P_30FPS_3_LAYERS` | 1920×1080@30，主层 3500 kbps，3 层（Simulcast） |
| `H264_720P_30FPS_3_LAYERS` | 1280×720@30，主层 1900 kbps，3 层 |
| `H264_540P_25FPS_2_LAYERS` | 960×540@25，主层 1000 kbps，2 层 |
| `H264_1080P_30FPS_1_LAYER` | 1080p 单层，无 Simulcast |
| `…_HIGH_MOTION` | 高码率变体，适合运动/游戏画面 |

> 转码耗资源：官方建议每 Ingress 实例 **≥4 CPU / ≥4 GB**。WHIP 旁路（`enable_transcoding=false`）
> 消耗最小。

### 3.6 管理 Ingress

| 操作 | CLI | SDK（示例） |
| --- | --- | --- |
| 列表 | `lk ingress list --room my-room` | `api.ingress.listIngress({ roomName })` |
| 更新（可换房间） | `lk ingress update ingress.json` | `api.ingress.updateIngress(id, {roomName})` |
| 删除 | `lk ingress delete <INGRESS_ID>` | `api.ingress.deleteIngress(id)` |

`IngressInfo.state.status`：`0` 空闲 · `1` 缓冲 · `2` 推流中 · `3` 错误 · `4` 结束。

### 3.7 需放行的端口（OBS 推流相关）

| 端口 | 协议 | 用途 |
| --- | --- | --- |
| 1935 | tcp | RTMP 推流 |
| 8080 | tcp | WHIP HTTP（可只放行回环，经 443 `/whip` 反代） |
| 7885 | udp | WHIP 媒体 |

### 3.8 OBS 推流排障

| 现象 | 排查 |
| --- | --- |
| 推流立即失败 | 1935 / 8080 未放行；或 `url`/`stream_key` 填错 |
| WHIP 连不上 | 443 的 `/whip` 反代没配；7885/udp 未放行；OBS 版本 < 28.1 |
| 连上但观众黑屏/无声 | livekit 媒体端口 20000–25000/udp 未放行 |
| 转码卡顿 | 实例 CPU 不足，改小预设或 WHIP 旁路 |

---

## 4. Egress（录制 / 转播）简介

> 官方参考：[Egress overview](https://docs.livekit.io/home/egress/overview/)

Egress 负责把房间**录制成文件**或**转播到第三方平台**。自托管需单独部署 `egress` 服务。

| 类型 | 说明 | 输出 |
| --- | --- | --- |
| RoomComposite | 录制整个房间（Chrome 渲染布局） | MP4 文件 / HLS |
| Participant | 录制单个参与者音视频 | MP4 |
| TrackComposite | 一条音频 + 一条视频合轨 | MP4 |
| Track | 单轨道直出（不转码） | 原始轨道 / WebSocket |
| Auto | 建房自动录制 | 随房间 |

输出类型：`file_outputs`（MP4）· `stream_outputs`（RTMP/SRT 转推）·
`segment_outputs`（HLS）· `image_outputs`（缩略图）。

> 本仓库当前**未部署 Egress**。如需录制，可按官方 [Egress 自托管](https://docs.livekit.io/transport/self-hosting/egress/) 部署后使用。

---

## 5. livekit-cli 命令速查

```bash
# 环境变量
export LIVEKIT_URL=https://xxx.xxxx.org
export LIVEKIT_API_KEY=xxx
export LIVEKIT_API_SECRET=xxx

# 令牌
lk token create --identity test --room my-room --join

# 房间
lk rooms list
lk rooms delete <room>

# Ingress（推流入口）
lk ingress create ingress.json
lk ingress list
lk ingress update ingress.json
lk ingress delete <id>

# Egress（录制，需先部署）
lk egress start-composite --room my-room --output file:///data/out.mp4
lk egress list
```

---

## 6. 参考文档

| 主题 | 链接 |
| --- | --- |
| 生成访问令牌 | https://docs.livekit.io/home/server/generating-tokens/ |
| 服务端 API | https://docs.livekit.io/reference/server/server-apis/ |
| Ingress 总览 | https://docs.livekit.io/home/ingress/overview/ |
| 编码器配置（OBS/FFmpeg/GStreamer） | https://docs.livekit.io/home/ingress/configure-streaming-software/ |
| Ingress API 参考 | https://docs.livekit.io/reference/other/ingress/api/ |
| Ingress 自托管 | https://docs.livekit.io/transport/self-hosting/ingress/ |
| Egress 总览 | https://docs.livekit.io/home/egress/overview/ |
| 自托管（VM，Docker+Caddy） | https://docs.livekit.io/transport/self-hosting/vm/ |
| LiveKit 服务器配置样例 | https://github.com/livekit/livekit/blob/master/config-sample.yaml |
