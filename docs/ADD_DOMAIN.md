# Cấu Trúc Nginx Configuration

## Cấu trúc thư mục

```
/etc/nginx/nginx.conf        (KHÔNG ĐỘNG)

/etc/nginx/backends/
    ingress.conf

/etc/nginx/conf.d/
    ingress_upstream.conf
    security.conf
    rate_limit.conf
    gzip.conf
    cache.conf

/etc/nginx/sites-available/
    kruzetech.dev

/etc/nginx/sites-enabled/
    kruzetech.dev -> ../sites-available/kruzetech.dev
```

---

## Setup trên VPS

### 1. Cài đặt Nginx (Nếu thêm cluster mới thì bỏ qua)

```bash
sudo apt update
sudo apt install nginx -y
```

---

### 2. Lấy IP của tất cả các node (workers:master)

**Cài jq:** trên master

```bash
sudo apt update
sudo apt install -y jq
```

**Lấy IP VPN:** trên master

```bash
ansible-inventory -i ~/k3s-inventory/hosts.ini --list \
| jq -r '
._meta.hostvars
| to_entries[]
| select(.value.ansible_user=="thang2k6adu")
| "server \(.value.vpn_ip):30443;"
'
```

**Phải ra:**

```nginx
server 10.10.10.11:30080;
server 10.10.10.13:30080;
server 10.10.10.12:30080;
```

---

### 3. Tạo backend list riêng (mỗi cluster 1 tên riêng)

```bash
sudo mkdir -p /etc/nginx/backends
sudo nano /etc/nginx/backends/cluster-prod.conf #sửa thành cluster chuẩn nhé
```

**Nội dung `/etc/nginx/backends/cluster-prod.conf`:**

```nginx
server 10.10.10.11:30443;
server 10.10.10.12:30443;
server 10.10.10.13:30443;
```

---

### 4. Tạo upstream Global (Thêm cluster mới thì bỏ qua)

```bash
sudo nano /etc/nginx/conf.d/ingress_upstream.conf
```

**Nội dung `/etc/nginx/conf.d/ingress_upstream.conf`: (cho cả 2 môi trường, thêm cluster nào thì add cái đấy)**

```nginx
upstream cluster-prod {
    least_conn;
    include /etc/nginx/backends/cluster-prod.conf;
}

upstream cluster-dev {
    least_conn;
    include /etc/nginx/backends/cluster-dev.conf;
}
```

---

### 5. Tạo security global (Thêm cluster mới thì bỏ qua)

```bash
sudo nano /etc/nginx/conf.d/security.conf
```

**Nội dung `/etc/nginx/conf.d/security.conf`:**

```nginx
server_tokens off;

add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options SAMEORIGIN always;
add_header Referrer-Policy strict-origin-when-cross-origin always;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
```

---

### 6. Rate limit global (Thêm cluster mới thì bỏ qua)

```bash
sudo nano /etc/nginx/conf.d/rate_limit.conf
```

**Nội dung `/etc/nginx/conf.d/rate_limit.conf`:**

```nginx
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
```

---

## Tạo script add domain

### Cấu hình domain mẫu

1 domain phải như này:

```nginx
server {
    listen 80;
    server_name kruzetech.dev www.kruzetech.dev;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name kruzetech.dev www.kruzetech.dev;

    ssl_certificate /etc/letsencrypt/live/kruzetech.dev/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/kruzetech.dev/privkey.pem;

    location / {
        proxy_pass https://ingress_prod;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
    }

    #Tách api riêng để rate limit
    location /api/ {
        limit_req zone=api_limit burst=20 nodelay;

        proxy_pass https://ingress_prod;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
    }
}
```

---

### Tạo script (Thêm cluster mới thì bỏ qua)

```bash
sudo nano /usr/local/bin/add-domain
sudo chmod +x /usr/local/bin/add-domain
```

**Cài certbot:**

```bash
sudo apt install -y certbot python3-certbot-nginx
```

**Nội dung `/usr/local/bin/add-domain`:**

```bash
#!/bin/bash

DOMAIN=$1
CLUSTER=$2   # cluster-dev | cluster-prod

if [ -z "$DOMAIN" ] || [ -z "$CLUSTER" ]; then
  echo "Usage: add-domain domain.com cluster-dev|cluster-prod"
  exit 1
fi

UPSTREAM="$CLUSTER"

CONF="/etc/nginx/sites-available/$DOMAIN"

if [ -f "$CONF" ]; then
  echo "Domain already exists: $DOMAIN"
  exit 1
fi

# Step 1: HTTP config (for certbot)
cat > $CONF <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        proxy_pass http://$UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

ln -s $CONF /etc/nginx/sites-enabled/$DOMAIN

nginx -t || exit 1
systemctl reload nginx

certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

cat > $CONF <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://$DOMAIN\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    return 301 https://$DOMAIN\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_pass https://$UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
    }

    location /api/ {
        limit_req zone=api_limit burst=20 nodelay;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_pass https://$UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
    }
}
EOF

nginx -t || exit 1
systemctl reload nginx

echo "Domain $DOMAIN added to $UPSTREAM"
```

---

## Các thao tác quản lý

### Thêm domain

```bash
sudo add-domain livekit.thang2k6adu.xyz cluster-dev
```

**Lưu ý:** thêm domain thì phải thêm www. nữa nhé

---

### Thêm node backend

```bash
echo "server 10.10.10.14:30443;" >> /etc/nginx/backends/ingress.conf
nginx -t && systemctl reload nginx
```

---

### Remove domain

```bash
DOMAIN=argocd.thang2k6adu.xyz

sudo rm -f /etc/nginx/sites-enabled/$DOMAIN
sudo rm -f /etc/nginx/sites-available/$DOMAIN
sudo certbot delete --cert-name $DOMAIN
sudo nginx -t && sudo systemctl reload nginx
```

---

## Thêm ingress cho K8s Dashboard

Vào core → kubernetes dashboard

**Tạo `dashboard-ingress.yaml`:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dashboard-ingress
  namespace: kubernetes-dashboard
  annotations:
    # bảo nginx ingress là service của cái này dùng HTTPS
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  rules:
  - host: dashboard.thang2k6adu.xyz
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kubernetes-dashboard
            port:
              number: 443
```

**Add domain:**

```bash
sudo add-domain dashboard.thang2k6adu.xyz cluster-dev
```

Commit rồi đẩy lên. Chờ gitops là xong.