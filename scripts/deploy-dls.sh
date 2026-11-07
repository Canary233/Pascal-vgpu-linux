#!/usr/bin/env bash
#
# deploy-dls.sh — 部署 FastAPI-DLS（vGPU license server，社区实现）
#
#   sudo bash deploy-dls.sh                       # 默认 4444 端口，自动探测本机 IP
#   sudo bash deploy-dls.sh --port 443 --url 10.0.5.2
#   sudo bash deploy-dls.sh --token-out /var/lib/vz/template/iso/client_configuration_token.tok
#
# 说明：
#   - 这是社区 license server 实现，等价于自建 NVIDIA DLS，绕过官方付费授权
#   - 家用/实验可接受，商用请购买正式 vGPU 授权
#   - 服务需长期在线：guest 每 24h 续期，宿主离线会在 lease 到期后掉回 Unlicensed
#
set -Eeuo pipefail

readonly DLS_REPO="https://git.collinwebdesigns.de/oscar.krause/fastapi-dls.git"
readonly BASE="/opt/fastapi-dls"
readonly SERVICE_USER="dls"
readonly ENV_FILE="/etc/fastapi-dls/env"

PORT="4444"
URL=""
ASSUME_YES=0
TOKEN_OUT=""

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi
log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --port)      PORT="${2:?}"; shift ;;
        --url)       URL="${2:?}"; shift ;;
        --token-out) TOKEN_OUT="${2:?}"; shift ;;
        --yes|-y)    ASSUME_YES=1 ;;
        --help|-h)   sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
    shift
done

(( EUID == 0 )) || die "需要 root 权限运行"

if [[ -z "${URL}" ]]; then
    URL="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [[ -n "${URL}" ]] || URL="$(hostname -I | awk '{print $1}')"
fi
[[ -n "${URL}" ]] || die "无法探测本机 IP，请用 --url 指定"
log "License 服务地址：https://${URL}:${PORT}"

if (( ! ASSUME_YES )); then
    read -r -p "确认部署？[y/N] " r
    [[ "${r}" =~ ^[Yy]$ ]] || exit 1
fi

# ---------------------------------------------------------------- 依赖

log "安装依赖"
apt-get update -qq
apt-get install -y -q python3-venv python3-pip curl git openssl >/dev/null

# ---------------------------------------------------------------- 代码

if [[ -d "${BASE}/app" ]]; then
    log "复用已有代码：${BASE}/app"
else
    log "拉取 fastapi-dls"
    rm -rf /var/tmp/fastapi-dls
    git clone --depth=1 -q "${DLS_REPO}" /var/tmp/fastapi-dls || die "克隆失败（检查网络或改用 GitHub 镜像）"
    mkdir -p "${BASE}"
    cp -a /var/tmp/fastapi-dls/app "${BASE}/app"
    cp -a /var/tmp/fastapi-dls/requirements.txt "${BASE}/"
fi

log "准备 Python 虚拟环境"
if [[ ! -x "${BASE}/venv/bin/uvicorn" ]]; then
    python3 -m venv "${BASE}/venv"
    "${BASE}/venv/bin/pip" install -q --upgrade pip
    "${BASE}/venv/bin/pip" install -q -r "${BASE}/requirements.txt"
fi

# ---------------------------------------------------------------- 证书

CERT_DIR="${BASE}/app/cert"
mkdir -p "${CERT_DIR}"
if [[ ! -f "${CERT_DIR}/webserver.crt" ]]; then
    log "生成自签 web 服务器证书（10 年，SAN=IP:${URL}）"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${CERT_DIR}/webserver.key" -out "${CERT_DIR}/webserver.crt" \
        -subj "/C=CN/ST=Local/L=Local/O=FastAPI-DLS/CN=${URL}" \
        -addext "subjectAltName=IP:${URL},DNS:localhost" >/dev/null 2>&1
fi
chmod 600 "${CERT_DIR}/webserver.key"

# ---------------------------------------------------------------- 配置与服务

id -u "${SERVICE_USER}" >/dev/null 2>&1 || useradd -r "${SERVICE_USER}" -M -d "${BASE}"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${BASE}"

log "写入配置 ${ENV_FILE}"
mkdir -p /etc/fastapi-dls
cat > "${ENV_FILE}" <<EOF
DLS_URL=${URL}
DLS_PORT=${PORT}
LEASE_EXPIRE_DAYS=90
DATABASE=sqlite:///${BASE}/app/db.sqlite
CERT_PATH=${CERT_DIR}
EOF
chmod 644 "${ENV_FILE}"

log "写入 systemd 服务"
cat > /etc/systemd/system/fastapi-dls.service <<EOF
[Unit]
Description=FastAPI-DLS vGPU licensing service (port ${PORT})
After=network-online.target
Wants=network-online.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${BASE}/app
EnvironmentFile=${ENV_FILE}
ExecStart=${BASE}/venv/bin/uvicorn main:app \\
  --env-file ${ENV_FILE} \\
  --host \${DLS_URL} --port \${DLS_PORT} \\
  --app-dir ${BASE}/app \\
  --ssl-keyfile ${CERT_DIR}/webserver.key \\
  --ssl-certfile ${CERT_DIR}/webserver.crt \\
  --proxy-headers
Restart=always
RestartSec=3
KillSignal=SIGQUIT
Type=simple
NotifyAccess=all

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now fastapi-dls >/dev/null 2>&1 || systemctl restart fastapi-dls
sleep 5

if ! systemctl is-active --quiet fastapi-dls; then
    die "服务启动失败：journalctl -u fastapi-dls -n 50 --no-pager"
fi
curl -sk --max-time 10 "https://${URL}:${PORT}/-/health" | grep -q '"status": "up"' \
    || die "健康检查失败：https://${URL}:${PORT}/-/health"
ok "License 服务运行中：https://${URL}:${PORT}"

# ---------------------------------------------------------------- 客户端令牌

[[ -n "${TOKEN_OUT}" ]] || TOKEN_OUT="/root/client_configuration_token.tok"
log "生成客户端令牌 → ${TOKEN_OUT}"
curl -sk --max-time 10 "https://${URL}:${PORT}/-/client-token" -o "${TOKEN_OUT}"
[[ -s "${TOKEN_OUT}" ]] || die "令牌生成失败"
chmod 644 "${TOKEN_OUT}"

ok "完成"
cat <<EOF

客户端令牌：${TOKEN_OUT}

Windows 客户机：
  1) 复制令牌到
     C:\\ProgramData\\NVIDIA Corporation\\vGPU Licensing\\ClientConfigToken\\
     （目录不存在则用 C:\\Program Files\\NVIDIA Corporation\\vGPU Licensing\\ClientConfigToken\\）
  2) 管理员 PowerShell：Restart-Service NVDisplay.ContainerLocalSystem
  3) 验证：& 'nvidia-smi' -q | Select-String "License"

Linux 客户机：
  cp ${TOKEN_OUT} /etc/nvidia/ClientConfigToken/
  systemctl restart nvidia-gridd
EOF
