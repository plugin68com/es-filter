#!/bin/bash

# ============================================================
#  ELK Stack Installer: Elasticsearch + Kibana - PRODUCTION
#  Ubuntu 20.04 / 22.04 / 24.04
#  Version: 8.x | SSL + Auth + Security ENABLED
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✔] $1${NC}"; }
warn()   { echo -e "${YELLOW}[!] $1${NC}"; }
error()  { echo -e "${RED}[✘] $1${NC}"; exit 1; }
header() { echo -e "\n${CYAN}${BOLD}========== $1 ==========${NC}\n"; }

# ============================================================
# KIỂM TRA ROOT
# ============================================================
if [ "$EUID" -ne 0 ]; then
  error "Vui lòng chạy với quyền root: sudo bash $0"
fi

# ============================================================
# CẤU HÌNH — chỉnh tại đây trước khi chạy
# ============================================================
ES_PORT=9200
KIBANA_PORT=5601
ES_HEAP="1g"          # 50% RAM, tối đa 31g. Ví dụ: 4GB RAM → 2g

# RAM detect tự động (có thể override ở trên)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
AUTO_HEAP=$(( TOTAL_RAM_MB / 2 ))m
if [ "$ES_HEAP" = "1g" ] && [ "$TOTAL_RAM_MB" -gt 2048 ]; then
  ES_HEAP="${AUTO_HEAP}"
  warn "Tự động đặt JVM heap: ${ES_HEAP} (50% RAM)"
fi

# ============================================================
# BƯỚC 1: Cập nhật hệ thống
# ============================================================
header "Bước 1: Cập nhật hệ thống"
apt-get update -y
apt-get install -y curl wget gnupg apt-transport-https \
  software-properties-common openssl pwgen ufw
log "Cập nhật xong"

# ============================================================
# BƯỚC 2: Java
# ============================================================
header "Bước 2: Kiểm tra Java"
if ! java -version &>/dev/null; then
  apt-get install -y openjdk-17-jdk
  log "Đã cài OpenJDK 17"
else
  log "Java đã có: $(java -version 2>&1 | head -1)"
fi

# ============================================================
# BƯỚC 3: Elastic repo
# ============================================================
header "Bước 3: Thêm Elastic repository"
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
  gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list

apt-get update -y
log "Elastic repo OK"

# ============================================================
# BƯỚC 4: Cài Elasticsearch
# ============================================================
header "Bước 4: Cài Elasticsearch"
apt-get install -y elasticsearch
log "Cài xong"

# ============================================================
# BƯỚC 5: Tạo SSL certificates
# ============================================================
header "Bước 5: Tạo SSL certificates (tự ký)"
CERT_DIR="/etc/elasticsearch/certs"
mkdir -p "$CERT_DIR"

# Tạo CA
/usr/share/elasticsearch/bin/elasticsearch-certutil ca \
  --out "$CERT_DIR/elastic-stack-ca.p12" \
  --pass "" --silent

# Tạo cert cho Elasticsearch
/usr/share/elasticsearch/bin/elasticsearch-certutil cert \
  --ca "$CERT_DIR/elastic-stack-ca.p12" \
  --ca-pass "" \
  --out "$CERT_DIR/elastic-certificates.p12" \
  --pass "" --silent

# Xuất PEM cho Kibana
/usr/share/elasticsearch/bin/elasticsearch-certutil cert \
  --ca "$CERT_DIR/elastic-stack-ca.p12" \
  --ca-pass "" \
  --pem \
  --out "$CERT_DIR/kibana-certs.zip" \
  --silent

cd "$CERT_DIR"
unzip -o kibana-certs.zip -d kibana-pem > /dev/null

# Xuất CA PEM
openssl pkcs12 -in "$CERT_DIR/elastic-stack-ca.p12" \
  -nokeys -out "$CERT_DIR/ca.crt" \
  -passin pass: 2>/dev/null

chown -R root:elasticsearch "$CERT_DIR"
chmod -R 750 "$CERT_DIR"
log "Tạo SSL xong"

# ============================================================
# BƯỚC 6: Cấu hình Elasticsearch (Production)
# ============================================================
header "Bước 6: Cấu hình Elasticsearch"

ES_CONFIG="/etc/elasticsearch/elasticsearch.yml"
cp "$ES_CONFIG" "${ES_CONFIG}.bak"

cat > "$ES_CONFIG" <<EOF
# ===================== Elasticsearch - PRODUCTION =====================

cluster.name: elk-production
node.name: node-1

network.host: 0.0.0.0
http.port: ${ES_PORT}

discovery.type: single-node

path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

# ---- SECURITY ----
xpack.security.enabled: true
xpack.security.enrollment.enabled: true

# HTTP (clients)
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.keystore.path: certs/elastic-certificates.p12
xpack.security.http.ssl.truststore.path: certs/elastic-certificates.p12

# Transport (node-to-node)
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.keystore.path: certs/elastic-certificates.p12
xpack.security.transport.ssl.truststore.path: certs/elastic-certificates.p12

# ---- MONITORING ----
xpack.monitoring.collection.enabled: true

# ---- PERFORMANCE ----
indices.memory.index_buffer_size: 20%
thread_pool.write.queue_size: 1000
EOF

# JVM Heap
cat > /etc/elasticsearch/jvm.options.d/heap.options <<EOF
-Xms${ES_HEAP}
-Xmx${ES_HEAP}
EOF

# Giới hạn memory swap
cat >> /etc/elasticsearch/jvm.options.d/heap.options <<EOF
-XX:+AlwaysPreTouch
EOF

# Tắt swap cho ES
echo "bootstrap.memory_lock: true" >> "$ES_CONFIG"

mkdir -p /etc/systemd/system/elasticsearch.service.d
cat > /etc/systemd/system/elasticsearch.service.d/override.conf <<EOF
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=65535
LimitNPROC=4096
EOF

# Kernel tuning cho production
cat >> /etc/sysctl.conf <<EOF

# Elasticsearch production tuning
vm.max_map_count=262144
vm.swappiness=1
net.core.somaxconn=65535
EOF
sysctl -p > /dev/null 2>&1

log "Cấu hình Elasticsearch xong"

# ============================================================
# BƯỚC 7: Khởi động Elasticsearch & lấy mật khẩu
# ============================================================
header "Bước 7: Khởi động Elasticsearch"
systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch

log "Đang chờ Elasticsearch sẵn sàng (tối đa 60s)..."
for i in {1..20}; do
  if curl -sk "https://localhost:${ES_PORT}" -u "elastic:changeme" > /dev/null 2>&1 || \
     curl -sk "https://localhost:${ES_PORT}" > /dev/null 2>&1; then
    break
  fi
  sleep 3
  echo -n "."
done
echo ""

# Reset mật khẩu elastic user
log "Đặt mật khẩu cho user 'elastic'..."
ES_PASSWORD=$(pwgen -s 20 1)

/usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u elastic -i --batch \
  --url "https://localhost:${ES_PORT}" \
  <<< "$ES_PASSWORD" 2>/dev/null || \
/usr/share/elasticsearch/bin/elasticsearch-reset-password \
  -u elastic --auto --batch \
  --url "https://localhost:${ES_PORT}" 2>/dev/null | \
  grep -oP '(?<=New value: ).*' > /tmp/es_pass_auto.txt && \
  ES_PASSWORD=$(cat /tmp/es_pass_auto.txt) || true

# Nếu auto-reset thất bại, dùng API
if [ -z "$ES_PASSWORD" ]; then
  ES_PASSWORD=$(pwgen -s 20 1)
  curl -sk -X POST "https://localhost:${ES_PORT}/_security/user/elastic/_password" \
    --cacert "$CERT_DIR/ca.crt" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"${ES_PASSWORD}\"}" || true
fi

log "Elasticsearch đang chạy ✓"

# ============================================================
# BƯỚC 8: Cài Kibana
# ============================================================
header "Bước 8: Cài Kibana"
apt-get install -y kibana
log "Cài Kibana xong"

# ============================================================
# BƯỚC 9: Tạo Kibana service token
# ============================================================
header "Bước 9: Tạo Kibana service token"

KIBANA_TOKEN=$(/usr/share/elasticsearch/bin/elasticsearch-service-tokens \
  create elastic/kibana kibana-prod 2>/dev/null | grep -oP '(?<=SERVICE_TOKEN elastic/kibana/kibana-prod = ).*' || true)

if [ -z "$KIBANA_TOKEN" ]; then
  KIBANA_TOKEN=$(curl -sk -X POST \
    "https://localhost:${ES_PORT}/_security/service/elastic/kibana/credential/token/kibana-token" \
    -u "elastic:${ES_PASSWORD}" \
    --cacert "$CERT_DIR/ca.crt" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['token']['value'])" 2>/dev/null || echo "")
fi

log "Service token tạo xong"

# ============================================================
# BƯỚC 10: Cấu hình Kibana (Production)
# ============================================================
header "Bước 10: Cấu hình Kibana"

# Copy cert cho Kibana
KIBANA_CERT_DIR="/etc/kibana/certs"
mkdir -p "$KIBANA_CERT_DIR"
cp "$CERT_DIR/kibana-pem/instance/instance.crt" "$KIBANA_CERT_DIR/kibana.crt"
cp "$CERT_DIR/kibana-pem/instance/instance.key" "$KIBANA_CERT_DIR/kibana.key"
cp "$CERT_DIR/ca.crt" "$KIBANA_CERT_DIR/ca.crt"
chown -R root:kibana "$KIBANA_CERT_DIR"
chmod -R 750 "$KIBANA_CERT_DIR"

KIBANA_CONFIG="/etc/kibana/kibana.yml"
cp "$KIBANA_CONFIG" "${KIBANA_CONFIG}.bak"

# Tạo encryption keys
ENC_KEY1=$(openssl rand -hex 32)
ENC_KEY2=$(openssl rand -hex 32)
ENC_KEY3=$(openssl rand -hex 32)

cat > "$KIBANA_CONFIG" <<EOF
# ===================== Kibana - PRODUCTION =====================

server.port: ${KIBANA_PORT}
server.host: "0.0.0.0"
server.name: "kibana-production"

# ---- HTTPS cho Kibana UI ----
server.ssl.enabled: true
server.ssl.certificate: /etc/kibana/certs/kibana.crt
server.ssl.key: /etc/kibana/certs/kibana.key

# ---- Kết nối Elasticsearch ----
elasticsearch.hosts: ["https://localhost:${ES_PORT}"]
elasticsearch.ssl.certificateAuthorities: ["/etc/kibana/certs/ca.crt"]
elasticsearch.ssl.verificationMode: certificate

# ---- Auth ----
EOF

if [ -n "$KIBANA_TOKEN" ]; then
cat >> "$KIBANA_CONFIG" <<EOF
elasticsearch.serviceAccountToken: "${KIBANA_TOKEN}"
EOF
else
cat >> "$KIBANA_CONFIG" <<EOF
elasticsearch.username: "kibana_system"
elasticsearch.password: "${ES_PASSWORD}"
EOF
fi

cat >> "$KIBANA_CONFIG" <<EOF

# ---- Encryption keys (bắt buộc cho production) ----
xpack.security.encryptionKey: "${ENC_KEY1}"
xpack.encryptedSavedObjects.encryptionKey: "${ENC_KEY2}"
xpack.reporting.encryptionKey: "${ENC_KEY3}"

# ---- Session ----
xpack.security.session.idleTimeout: "1h"
xpack.security.session.lifespan: "8h"

# ---- Monitoring ----
monitoring.ui.ccs.enabled: false
telemetry.enabled: false

# ---- Logging ----
logging.appenders.file.type: file
logging.appenders.file.fileName: /var/log/kibana/kibana.log
logging.appenders.file.layout.type: json
logging.root.appenders: [default, file]
logging.root.level: warn
EOF

log "Cấu hình Kibana xong"

# ============================================================
# BƯỚC 11: Khởi động Kibana
# ============================================================
header "Bước 11: Khởi động Kibana"
systemctl daemon-reload
systemctl enable kibana
systemctl start kibana
log "Kibana đã khởi động"

# ============================================================
# BƯỚC 12: Firewall
# ============================================================
header "Bước 12: Cấu hình Firewall (UFW)"
ufw --force enable > /dev/null 2>&1 || true
ufw allow ssh
ufw allow ${KIBANA_PORT}/tcp comment "Kibana HTTPS"
# ES port chỉ mở local (không expose ra ngoài cho production)
# Nếu cần truy cập ES từ ngoài: ufw allow ${ES_PORT}/tcp
ufw reload > /dev/null 2>&1 || true
log "Firewall: SSH + Kibana(:${KIBANA_PORT}) mở. ES(:${ES_PORT}) chỉ localhost"

# ============================================================
# BƯỚC 13: Logrotate
# ============================================================
cat > /etc/logrotate.d/elasticsearch <<EOF
/var/log/elasticsearch/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  sharedscripts
  postrotate
    systemctl reload elasticsearch > /dev/null 2>&1 || true
  endscript
}
EOF

cat > /etc/logrotate.d/kibana <<EOF
/var/log/kibana/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
}
EOF
log "Logrotate đã cấu hình (giữ 14 ngày)"

# ============================================================
# LƯU THÔNG TIN ĐĂNG NHẬP
# ============================================================
CRED_FILE="/root/.elk-credentials"
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

cat > "$CRED_FILE" <<EOF
# ============================================================
#  ELK PRODUCTION — THÔNG TIN ĐĂNG NHẬP
#  Tạo lúc: $(date)
# ============================================================

Elasticsearch URL : https://${PUBLIC_IP}:${ES_PORT}
Kibana URL        : https://${PUBLIC_IP}:${KIBANA_PORT}

[Tài khoản Elasticsearch]
Username : elastic
Password : ${ES_PASSWORD}

[Kibana Service Token]
Token    : ${KIBANA_TOKEN}

[Certificates]
CA cert  : /etc/elasticsearch/certs/ca.crt
ES cert  : /etc/elasticsearch/certs/elastic-certificates.p12
Kibana   : /etc/kibana/certs/

[Encryption Keys - Kibana]
Key1: ${ENC_KEY1}
Key2: ${ENC_KEY2}
Key3: ${ENC_KEY3}

QUAN TRỌNG: Sao lưu file này và xóa sau khi đã lưu trữ an toàn!
EOF
chmod 600 "$CRED_FILE"

# ============================================================
# KẾT QUẢ
# ============================================================
echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}   CÀI ĐẶT HOÀN TẤT — PRODUCTION READY!${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
echo -e "  ${CYAN}Kibana (HTTPS):${NC}        https://${PUBLIC_IP}:${KIBANA_PORT}"
echo -e "  ${CYAN}Elasticsearch (HTTPS):${NC} https://${PUBLIC_IP}:${ES_PORT}"
echo ""
echo -e "  ${CYAN}Username:${NC}  elastic"
echo -e "  ${CYAN}Password:${NC}  ${BOLD}${ES_PASSWORD}${NC}"
echo ""
echo -e "  ${YELLOW}⚠  Thông tin đăng nhập đã lưu tại: ${BOLD}${CRED_FILE}${NC}"
echo ""
echo -e "  ${CYAN}Lệnh hữu ích:${NC}"
echo -e "  systemctl status elasticsearch kibana"
echo -e "  journalctl -u elasticsearch -f"
echo -e "  journalctl -u kibana -f"
echo ""
echo -e "  ${YELLOW}Ghi chú:${NC}"
echo -e "  - Kibana dùng HTTPS, trình duyệt có thể cảnh báo self-signed cert → chọn 'Advanced > Proceed'"
echo -e "  - Kibana mất 1-2 phút để load lần đầu"
echo -e "  - ES port 9200 chỉ mở localhost. Mở ra ngoài nếu cần: ufw allow 9200/tcp"
echo -e "  - Đổi mật khẩu sau lần đăng nhập đầu tiên!"
echo ""
