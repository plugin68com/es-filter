#!/bin/bash

#####################################
# ELK Stack Installer - Final Version
# Ubuntu 24.04 LTS
# With Elasticsearch API proxy
#####################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }
warning() { echo -e "${YELLOW}⚠${NC} $1"; }

# Config
DOMAIN="search.isures.com"
ES_VERSION="8.x"

# Root check
[ "$EUID" -ne 0 ] && error "Run as root"

clear
echo "╔════════════════════════════════════════╗"
echo "║   ELK Stack Installer - Ubuntu 24.04  ║"
echo "╚════════════════════════════════════════╝"
echo ""

#####################################
# 1. SWAP
#####################################
echo "━━━ [1/8] SWAP Setup ━━━"
RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
SWAP_MB=$(free -m | awk '/Swap:/ {print $2}')
log "RAM: ${RAM_MB}MB, SWAP: ${SWAP_MB}MB"

if [ $SWAP_MB -eq 0 ]; then
    SWAP_SIZE=$((RAM_MB * 2))
    [ $SWAP_SIZE -gt 4096 ] && SWAP_SIZE=4096
    
    log "Creating ${SWAP_SIZE}MB swap..."
    dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    
    sysctl -w vm.swappiness=10 >/dev/null
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    
    success "SWAP: ${SWAP_SIZE}MB"
else
    success "SWAP exists: ${SWAP_MB}MB"
fi
echo ""

#####################################
# 2. SSL CERTIFICATES
#####################################
echo "━━━ [2/8] SSL Certificates ━━━"
mkdir -p /etc/ssl/cloudflare
CERT_FILE="/etc/ssl/cloudflare/fullchain.pem"
KEY_FILE="/etc/ssl/cloudflare/privkey.pem"

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    success "SSL certificates exist"
else
    log "Paste Cloudflare Origin Certificate (Ctrl+D when done):"
    cat > "$CERT_FILE"
    log "Paste Private Key (Ctrl+D when done):"
    cat > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    success "SSL saved"
fi
echo ""

#####################################
# 3. SYSTEM PREP
#####################################
echo "━━━ [3/8] System Preparation ━━━"
log "Installing packages..."
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg

sysctl -w vm.max_map_count=262144 >/dev/null
grep -q "vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf

success "System ready"
echo ""

#####################################
# 4. ELASTICSEARCH
#####################################
echo "━━━ [4/8] Elasticsearch ━━━"
log "Adding repository..."
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
    gpg --dearmor -o /usr/share/keyrings/elastic.gpg

echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/${ES_VERSION}/apt stable main" \
    > /etc/apt/sources.list.d/elastic.list

apt-get update -qq
log "Installing Elasticsearch..."
apt-get install -y -qq elasticsearch

mkdir -p /var/lib/elasticsearch /var/log/elasticsearch
chown -R elasticsearch:elasticsearch /var/lib/elasticsearch /var/log/elasticsearch

success "Elasticsearch installed"
echo ""

#####################################
# 5. ELASTICSEARCH CONFIG
#####################################
echo "━━━ [5/8] Configuring Elasticsearch ━━━"

HEAP_MB=$((RAM_MB * 40 / 100))
[ $HEAP_MB -lt 256 ] && HEAP_MB=256
[ $HEAP_MB -gt 2048 ] && HEAP_MB=2048
log "Heap: ${HEAP_MB}MB"

mkdir -p /etc/elasticsearch/jvm.options.d
cat > /etc/elasticsearch/jvm.options.d/heap.options <<EOF
-Xms${HEAP_MB}m
-Xmx${HEAP_MB}m
EOF

cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
cluster.name: elk-cluster
node.name: node-1
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node

# Security enabled
xpack.security.enabled: true
xpack.security.enrollment.enabled: true
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
EOF

chown -R elasticsearch:elasticsearch /etc/elasticsearch

# Clean old keystore
if [ -f /etc/elasticsearch/elasticsearch.keystore ]; then
    /usr/share/elasticsearch/bin/elasticsearch-keystore remove \
        xpack.security.transport.ssl.keystore.secure_password 2>/dev/null || true
    /usr/share/elasticsearch/bin/elasticsearch-keystore remove \
        xpack.security.transport.ssl.truststore.secure_password 2>/dev/null || true
fi

log "Starting Elasticsearch..."
systemctl daemon-reload
systemctl enable elasticsearch >/dev/null 2>&1
systemctl restart elasticsearch

log "Waiting..."
for i in {1..60}; do
    if curl -s http://127.0.0.1:9200 >/dev/null 2>&1; then
        success "Elasticsearch running"
        break
    fi
    sleep 2
done
echo ""

#####################################
# 6. GENERATE PASSWORDS
#####################################
echo "━━━ [6/8] Security Setup ━━━"
log "Generating passwords..."

ELASTIC_PASS=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b 2>/dev/null | grep "New value:" | awk '{print $3}')
KIBANA_PASS=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system -b 2>/dev/null | grep "New value:" | awk '{print $3}')

[ -z "$ELASTIC_PASS" ] && error "Password generation failed"

success "Passwords generated"
echo ""

#####################################
# 7. KIBANA
#####################################
echo "━━━ [7/8] Kibana ━━━"
log "Installing Kibana..."
apt-get install -y -qq kibana

# Memory limit
mkdir -p /etc/systemd/system/kibana.service.d
cat > /etc/systemd/system/kibana.service.d/override.conf <<EOF
[Service]
Environment="NODE_OPTIONS=--max-old-space-size=512"
TimeoutStartSec=900
EOF

cat > /etc/kibana/kibana.yml <<EOF
server.port: 5601
server.host: "127.0.0.1"
server.name: "${DOMAIN}"
elasticsearch.hosts: ["http://127.0.0.1:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_PASS}"
EOF

mkdir -p /var/log/kibana
chown -R kibana:kibana /var/log/kibana

log "Starting Kibana (2-3 minutes)..."
systemctl daemon-reload
systemctl enable kibana >/dev/null 2>&1
systemctl start kibana

log "Waiting for Kibana..."
for i in {1..120}; do
    if curl -s http://127.0.0.1:5601/api/status >/dev/null 2>&1; then
        success "Kibana running"
        break
    fi
    [ $((i % 10)) -eq 0 ] && echo -n " ${i}s"
    sleep 1
done
echo ""
echo ""

#####################################
# 8. NGINX WITH ES API PROXY
#####################################
echo "━━━ [8/8] Nginx ━━━"
apt-get install -y -qq nginx

cat > /etc/nginx/sites-available/kibana <<'NGINXCONF'
upstream kibana {
    server 127.0.0.1:5601;
}

upstream elasticsearch {
    server 127.0.0.1:9200;
}

server {
    listen 443 ssl http2;
    server_name DOMAIN_PLACEHOLDER;
    
    ssl_certificate /etc/ssl/cloudflare/fullchain.pem;
    ssl_certificate_key /etc/ssl/cloudflare/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    # Increase body size for bulk indexing
    client_max_body_size 100M;
    
    # Elasticsearch API routes (must come BEFORE location /)
    location ~ ^/(woo_products|products|_bulk|_search|_doc|_cluster|_cat|_count|_mapping|_index|_settings|_alias) {
        proxy_pass http://elasticsearch;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        
        # Timeouts for long-running queries
        proxy_connect_timeout 90s;
        proxy_send_timeout 90s;
        proxy_read_timeout 90s;
    }
    
    # Kibana UI (catch-all, must come AFTER ES routes)
    location / {
        proxy_pass http://kibana;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}

server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    return 301 https://$server_name$request_uri;
}
NGINXCONF

sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" /etc/nginx/sites-available/kibana

ln -sf /etc/nginx/sites-available/kibana /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

success "Nginx configured"
echo ""

#####################################
# DONE
#####################################
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║                  ✅ INSTALLATION COMPLETE! 🎉                 ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌐 ACCESS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "   Kibana UI: ${YELLOW}https://${DOMAIN}${NC}"
echo "   ES API:    ${YELLOW}https://${DOMAIN}/woo_products/_search${NC}"
echo ""
echo "   Username: ${GREEN}elastic${NC}"
echo "   Password: ${GREEN}${ELASTIC_PASS}${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔑 CREATE API KEY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "   Login to Kibana → Management → API Keys → Create"
echo ""
echo "   Or use Dev Tools:"
echo ""
echo "   POST /_security/api_key"
echo "   {"
echo '     "name": "wordpress_indexing",'
echo '     "role_descriptors": {'
echo '       "indexing_role": {'
echo '         "cluster": ["monitor"],'
echo '         "indices": [{'
echo '           "names": ["woo_products*"],'
echo '           "privileges": ["all"]'
echo "         }]"
echo "       }"
echo "     },"
echo '     "expiration": "365d"'
echo "   }"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 USAGE EXAMPLES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "   # Index document"
echo "   curl -X POST 'https://${DOMAIN}/woo_products/_doc' \\"
echo "     -H 'Authorization: ApiKey YOUR_API_KEY' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"name\":\"Product\",\"price\":99}'"
echo ""
echo "   # Search"
echo "   curl -X GET 'https://${DOMAIN}/woo_products/_search' \\"
echo "     -H 'Authorization: ApiKey YOUR_API_KEY'"
echo ""
echo "   # PHP Code:"
echo "   \$client = ClientBuilder::create()"
echo "       ->setHosts(['https://${DOMAIN}'])"
echo "       ->setApiKey('YOUR_API_KEY')"
echo "       ->setSSLVerification(false)"
echo "       ->build();"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 SERVICES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for svc in elasticsearch kibana nginx; do
    if systemctl is-active --quiet $svc; then
        echo "   ${GREEN}✓${NC} $svc"
    else
        echo "   ${RED}✗${NC} $svc"
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💾 MEMORY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
free -h | grep -E "Mem:|Swap:"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🎉 Ready! Access: https://${DOMAIN}"
echo ""
