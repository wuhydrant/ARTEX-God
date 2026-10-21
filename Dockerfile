# ARTEX Docker 镜像：Go 单二进制（内嵌前端）+ 运行时工具链
#
# 产物用途：
#   docker build .                          # 本地全量构建（前端 + Go），配合 docker-compose.yml
#   docker build --build-arg VERSION=v0.3.15 .  # 带版本号构建（可解锁页面一键更新）
#
# 与 .github/workflows/release.yml 的 docker job 配套：该 job 用 buildx 一次产出
# linux/amd64 + linux/arm64 双架构镜像。编译两个阶段都钉在 --platform=$BUILDPLATFORM
# 上（前端是平台无关的静态文件；Go 用 GOARCH=$TARGETARCH 交叉编译），多架构构建
# 全程跑在构建机原生平台上，不为编译付 QEMU 模拟的开销——只有最后的运行时层
# （apt 安装）按目标架构执行。
#
# 注意：main.go 默认 version=dev，而自更新对 dev 构建是禁用的——镜像构建不传
# VERSION 也无妨，容器内升级请走 compose pull（见 README 更新升级一节）。

ARG GO_VERSION=1.26
ARG NODE_VERSION=22

# Go 模块代理。default 用官方值；proxy.golang.org 不可达的境内网络请覆盖：
#   docker compose：在 .env 里设置 GOPROXY=https://goproxy.cn,direct
#   docker build：--build-arg GOPROXY=https://goproxy.cn,direct
ARG GOPROXY=https://proxy.golang.org,direct

# ── 阶段 1：前端静态导出 ─────────────────────────────────────────────
# 对应 npm run build:static → web/out/。npm ci 先只拷 lock 文件，让依赖安装
# 结果命中 Docker 层缓存；仅在源码变化时才重新执行构建。
FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine AS frontend
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY web ./
RUN npm run build:static

# ── 阶段 2：Go 交叉编译 ──────────────────────────────────────────────
# CGO_ENABLED=0（与 build.sh / release 工作流一致，纯 Go + modernc sqlite），
# 产物静态链接，可直接放进任意发行版运行时。schema.sql、webui/dist 经
# go:embed 打进单二进制，运行镜像不再需要源码。
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-bookworm AS build
ARG TARGETARCH
ARG VERSION=dev
ARG GOPROXY
ENV CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} GOPROXY=${GOPROXY}
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
# 前端静态产物拷进内嵌目录（覆盖 .dockerignore 排除的任何历史 dist），
# 必须在 COPY . . 之后，embed 才拿得到。build:embedui 找不到该目录会编译失败。
COPY --from=frontend /src/web/out server/webui/dist
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -tags embedui -trimpath \
      -ldflags "-s -w -X main.version=${VERSION}" \
      -o /out/artex ./cmd/artex

# ── 阶段 3：运行时 ───────────────────────────────────────────────────
# 结构对应二进制分发的 zip：/app/artex + /app/skills/。运行时目录约定：
#   /app/data    data/ 数据目录（SQLite 流量索引、MITM CA 证书、任务文件）→ 挂卷持久化
#   /app/skills  内置技能 → 可挂卷/挂目录替换
#   /app/jwt.key 运行时生成的 JWT 签名密钥（容器可写层；重建容器会重新生成，
#                仅影响已登录会话，管理员密码存在 PostgreSQL 里不受影响）
#
# 工具链：worker 的 Bash 工具在本容器里执行，所以镜像要预装渗透基础工具。
# 下面是通用侦察基线，按需在这里增删（例如 apt 里加 whatweb、nikto、ffuf）。
FROM debian:bookworm-slim AS runtime

# 运行时 apt 包不钉具体版本（hadolint DL3008）：bookworm 发行版包会随
# 点版本更新而移动，钉 sha 版本号会让"加一个工具"这类用户自制镜像频繁失配。
# 更靠谱的"可复现"是把整条 apt 层内容锁进你自己的镜像仓库 tag 里。
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        # init：norma 的 Bash 工具走 PTY + 子进程，反应式回收防僵尸进程
        tini \
        # 外发 TLS（LLM API、更新下载）与自签 CA 验证链所需的根证书
        ca-certificates \
        # agent 常用的命令行基线
        curl jq netbase openssl \
        # 侦察基线：端口/服务、网络探测、DNS、协议握手
        nmap netcat-openbsd dnsutils whois \
        # 脚本与解包：自定义工具的 script 类（Python）、归档/仓库处理
        python3 git unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /out/artex /app/artex
COPY skills/ /app/skills/

# 8787 = Web UI + API；8788 = 记录式 MITM 代理。8788 以裸端口 ":8788" 启动
# （见 CMD）：绑定全部网卡以允许宿主映射，而 traffic.ProxyAddr() 会把裸端口
# 映射回 127.0.0.1 供容器内 worker 走回环，两端都不需要改代码。
EXPOSE 8787 8788

# /api/health 免鉴权（server/auth.go 白名单），返回版本信息，适合当健康检查。
# 记得在镜像里保留 curl —— 它同时也是容器的健康检查工具。
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:8787/api/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
# 默认参数与 README 的 ./start.sh 用法一致。
CMD ["/app/artex", "-addr", ":8787", "-proxy", ":8788"]
