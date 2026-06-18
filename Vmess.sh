#!/bin/bash

set +e

# =========================================
# SHELL DEPLOYER BY RAFAEL R.
# FINAL FIX: VMess + LOG CHECKER ADDED
# =========================================

# =========================
# COLORS
# =========================
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# =========================
# VARIABLES
# =========================
PROJECT_ID="$(gcloud config get-value project)"
REGION="us-central1"
RAND=$(openssl rand -hex 3)
CLOUD_RUN_SERVICE_NAME="rafael-$RAND"
DOMAIN="www.google.com"
BUILD_DIR=$(mktemp -d)

# =========================
# CLEANUP
# =========================
cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# =========================
# HEADER
# =========================
clear
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}       SHELL DEPLOYER BY RAFAEL R.${NC}"
echo -e "${GREEN}          VMess + LOGS VERSION${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# =========================
# CHECK PROJECT
# =========================
if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}ERROR: No Google Cloud project set.${NC}"
    echo "Run: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

# =========================
# ENABLE REQUIRED APIS
# =========================
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}        ENABLING REQUIRED APIS${NC}"
echo -e "${CYAN}=========================================${NC}"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com logging.googleapis.com

# =========================
# BILLING SETTINGS
# =========================
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}          BILLING SETTINGS${NC}"
echo -e "${CYAN}=========================================${NC}"
echo -e "${WHITE}1) REQUEST-BASED | 2) INSTANCE-BASED${NC}"
while true; do
    read -p "Select Billing Type [1-2]: " BILLING_CHOICE
    case $BILLING_CHOICE in
        1) BILLING_MODE="request"; break ;;
        2) BILLING_MODE="instance"; break ;;
        *) echo -e "${RED}Invalid choice${NC}" ;;
    esac
done

# =========================
# RESOURCE SETTINGS
# =========================
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}      CLOUD RUN RESOURCE SETTINGS${NC}"
echo -e "${CYAN}=========================================${NC}"
echo "Memory: 1=512Mi 2=1Gi 3=2Gi 4=4Gi 5=8Gi 6=16Gi 7=32Gi"
while true; do
    read -p "Select Memory: " MEMORY_CHOICE
    case $MEMORY_CHOICE in
        1) MEMORY="512Mi"; break ;;
        2) MEMORY="1Gi"; break ;;
        3) MEMORY="2Gi"; break ;;
        4) MEMORY="4Gi"; break ;;
        5) MEMORY="8Gi"; break ;;
        6) MEMORY="16Gi"; break ;;
        7) MEMORY="32Gi"; break ;;
        *) echo -e "${RED}Invalid${NC}" ;;
    esac
done

echo "vCPU: 1=1 2=2 3=4 4=6 5=8"
while true; do
    read -p "Select vCPU: " CPU_CHOICE
    case $CPU_CHOICE in
        1) CPU="1"; break ;;
        2) CPU="2"; break ;;
        3) CPU="4"; break ;;
        4) CPU="6"; break ;;
        5) CPU="8"; break ;;
        *) echo -e "${RED}Invalid${NC}" ;;
    esac
done

CONCURRENCY="1000"
TIMEOUT="3600"
SPECIAL_MODE=$([ "$MEMORY" = "4Gi" ] && [ "$CPU" = "4" ] && echo "true" || echo "false")

# =========================
# INSTANCE SETTINGS
# =========================
while true; do
    read -p "Min Instances [0-1]: " MIN_INST
    MIN_INST=${MIN_INST:-0}
    [[ "$MIN_INST" =~ ^[01]$ ]] && break
done

if [ "$SPECIAL_MODE" = "true" ]; then
    while true; do
        read -p "Max Instances [1-4]: " MAX_INST
        MAX_INST=${MAX_INST:-1}
        [[ "$MAX_INST" =~ ^[1-4]$ ]] && break
    done
else
    while true; do
        read -p "Max Instances [0-2]: " MAX_INST
        MAX_INST=${MAX_INST:-0}
        [[ "$MAX_INST" =~ ^[0-2]$ ]] && break
    done
fi

# =========================
# CREATE FILES
# =========================
mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR" || exit 1

# --- CONFIG.JSON (NA-AYOS NA VMess) ---
cat > config.json <<EOF
{
  "log": {
    "loglevel": "info",
    "access": "/dev/stdout",
    "error": "/dev/stderr"
  },
  "inbounds": [
    {
      "tag": "trojan-ws",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [{ "password": "rafaeltv" }] },
      "sniffing": { "enabled": true, "metadataOnly": false },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-rafael" } }
    },
    {
      "tag": "vless-ws",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1", "level": 0 }], "decryption": "none" },
      "sniffing": { "enabled": true, "metadataOnly": false },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-rafael" } }
    },
    {
      "tag": "vmess-ws",
      "port": 11004,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [{
          "id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1",
          "alterId": 0,
          "security": "auto",
          "level": 0
        }]
      },
      "sniffing": { "enabled": true, "metadataOnly": false },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess-rafael",
          "headers": { "Host": "" }
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF

# --- NGINX.CONF (KUMPLETONG PROXY PARA SA VMess) ---
cat > nginx.conf <<EOF
worker_processes auto;
worker_rlimit_nofile 200000;
events { worker_connections 65535; multi_accept on; }
http {
    sendfile on; tcp_nopush on; tcp_nodelay on;
    keepalive_timeout 65; keepalive_requests 100000;
    client_max_body_size 0;
    proxy_connect_timeout 300; proxy_send_timeout 86400; proxy_read_timeout 86400;
    proxy_buffering off; proxy_request_buffering off; server_tokens off;

    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

    server {
        listen 8080;

        location / {
            proxy_pass https://$DOMAIN;
            proxy_set_header Host $DOMAIN;
        }

        location /trojan-rafael {
            proxy_pass http://127.0.0.1:10001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
        }

        location /vless-rafael {
            proxy_pass http://127.0.0.1:10002;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
        }

        location /vmess-rafael {
            proxy_pass http://127.0.0.1:11004;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-For \$remote_addr;
        }
    }
}
EOF

# --- ENTRYPOINT ---
cat > entrypoint.sh <<EOF
#!/bin/sh
echo "Starting Xray..."
/usr/local/bin/xray run -c /etc/xray.json &
XR_PID=\$!
sleep 3
echo "Starting Nginx..."
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
EOF
chmod +x entrypoint.sh

# --- DOCKERFILE ---
cat > Dockerfile <<EOF
FROM alpine:3.19 AS xray-bin
RUN apk add --no-cache curl unzip
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip \
    && unzip xray.zip \
    && mv xray /usr/local/bin/ \
    && rm -f xray.zip

FROM openresty/openresty:alpine-fat
RUN apk add --no-cache ca-certificates bash
COPY --from=xray-bin /usr/local/bin/xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

# =========================
# BUILD & DEPLOY
# =========================
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}          BUILDING IMAGE${NC}"
echo -e "${CYAN}=========================================${NC}"
gcloud builds submit --tag gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME . --quiet

[ "$BILLING_MODE" = "instance" ] && BF="--no-cpu-throttling" || BF="--cpu-throttling"

echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}         DEPLOYING CLOUD RUN${NC}"
echo -e "${CYAN}=========================================${NC}"
gcloud run deploy $CLOUD_RUN_SERVICE_NAME \
  --image gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME \
  --platform managed --region $REGION --allow-unauthenticated \
  --port 8080 --memory $MEMORY --cpu $CPU --concurrency $CONCURRENCY \
  --timeout $TIMEOUT --min-instances $MIN_INST --max-instances $MAX_INST \
  --execution-environment gen2 --cpu-boost $BF --quiet

CLOUD_RUN_URL=$(gcloud run services describe $CLOUD_RUN_SERVICE_NAME --region=$REGION --format='value(status.url)' | sed 's|https://||')

# =========================
# OUTPUT
# =========================
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}✅ DEPLOYMENT SUCCESSFUL${NC}"
echo -e "${CYAN}=========================================${NC}"
echo "Service Name: $CLOUD_RUN_SERVICE_NAME"
echo "Host: $CLOUD_RUN_URL"
echo ""

# --- VMess Link ---
VMESS_B64=$(echo -n "{\"v\":\"2\",\"ps\":\"STS NO LOAD BY RAF - VMESS\",\"add\":\"$CLOUD_RUN_URL\",\"port\":\"443\",\"id\":\"15f7e8ea-7b56-45d4-93af-31f3c592fdf1\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$CLOUD_RUN_URL\",\"path\":\"/vmess-rafael\",\"tls\":\"tls\",\"sni\":\"firebase-settings.crashlytics.com\",\"fp\":\"chrome\",\"alpn\":\"h2,http/1.1\"}" | base64 -w 0)

echo -e "${GREEN}🔗 VMess Link:${NC}"
echo "vmess://$VMESS_B64"
echo ""

echo -e "${CYAN}=========================================${NC}"
echo -e "${YELLOW}📋 CHECK SERVER LOGS NOW:${NC}"
echo -e "${CYAN}=========================================${NC}"
echo "gcloud run services logs tail $CLOUD_RUN_SERVICE_NAME --region=$REGION"
echo ""
echo "Or view last 50 lines:"
echo "gcloud logging read \"resource.labels.service_name=$CLOUD_RUN_SERVICE_NAME\" --limit=50"
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}DONE${NC}"
echo -e "${CYAN}=========================================${NC}"

