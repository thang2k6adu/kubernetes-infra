# Cấu Trúc Nginx Configuration

## Cấu trúc thư mục

```
/etc/nginx/nginx.conf        (KHÔNG ĐỘNG)

/etc/nginx/backends/
    cluster-prod.conf
    cluster-dev.conf     (mỗi cluster 1 file riêng, tên khớp với upstream trong ingress_upstream.conf)

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
| "server \(.value.vpn_ip):30080;"
'
```

**Phải ra:**

```nginx
server 10.10.10.11:30080;
server 10.10.10.12:30080;
```

---

## **. Mở file cấu hình chính của Nginx (VPS)

```bash
sudo nano /etc/nginx/nginx.conf
```

Tìm trong block `http {}` và thêm đoạn sau **trước các dòng `include`**:

```nginx
## Virtual Host Configs
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

# Phân biệt REST vs websocket theo header Upgrade, KHÔNG theo path
# (path socket không cố định giữa các service - có thể /, /api, /sso/api...)
# Request websocket sẽ có key rỗng -> limit_req bỏ qua, không rate limit
map $http_upgrade $limit_key {
    default $binary_remote_addr;
    'websocket' '';
}

include /etc/nginx/conf.d/*.conf;
include /etc/nginx/sites-enabled/*;
```

---

### 3. Tạo backend list riêng (mỗi cluster 1 tên riêng)

```bash
sudo mkdir -p /etc/nginx/backends
sudo nano /etc/nginx/backends/cluster-prod.conf #sửa thành cluster chuẩn nhé
```

**Nội dung `/etc/nginx/backends/cluster-prod.conf`:**

```nginx
server 10.10.10.11:30080;
server 10.10.10.12:30080;
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
# Key dùng $limit_key (map ở nginx.conf) thay vì $binary_remote_addr trực tiếp,
# để tự động bỏ qua rate limit cho request websocket (Upgrade header)
limit_req_zone $limit_key zone=api_limit:10m rate=10r/s;
```

---

## Tạo script add domain

### Cấu hình domain mẫu

1 domain phải như này:

```nginx
server {
    listen 80;
    server_name kruzetech.dev;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name kruzetech.dev;

    ssl_certificate /etc/letsencrypt/live/kruzetech.dev/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/kruzetech.dev/privkey.pem;

    # Header chung cho cả REST lẫn websocket - khai 1 lần ở server, location kế thừa
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    location / {
        limit_req zone=api_limit burst=20 nodelay;   # tự bỏ qua cho websocket nhờ $limit_key rỗng

        # proxy_read_timeout không nhận biến và không đặt được trong if,
        # nên request websocket được đẩy sang named location @websocket (timeout dài).
        # Tự động theo header Upgrade - không cần khai path hay flag gì cho từng domain.
        if ($http_upgrade) {
            return 418;
        }
        error_page 418 = @websocket;

        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        proxy_pass http://ingress_prod;
    }

    location @websocket {
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_pass http://ingress_prod;
    }
}
```

---

**Cài certbot:**

```bash
sudo apt install -y certbot python3-certbot-nginx
```

### Tạo script (Thêm cluster mới thì bỏ qua)

```bash
sudo nano /usr/local/bin/add-domain
sudo chmod +x /usr/local/bin/add-domain
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
    server_name $DOMAIN;

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

certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

cat > $CONF <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://$DOMAIN\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # Header chung cho cả REST lẫn websocket - khai 1 lần ở server, location kế thừa
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # 1 location duy nhất cho cả domain - không giả định path /api cố định
    # (path socket của từng service không cố định, có thể /, /api, /sso/api...).
    location / {
        limit_req zone=api_limit burst=20 nodelay;   # tự bỏ qua cho websocket nhờ \$limit_key rỗng

        # Websocket -> @websocket (timeout 600s), REST giữ 60s.
        # Tự động theo header Upgrade, không cần flag hay path riêng cho từng domain.
        if (\$http_upgrade) {
            return 418;
        }
        error_page 418 = @websocket;

        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        proxy_pass http://$UPSTREAM;
    }

    location @websocket {
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_pass http://$UPSTREAM;
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
sudo add-domain katech-admin-ui.kruzetech.dev cluster-prod
```

**Lưu ý:**
- Script không tự thêm `www.<domain>` nữa — add domain nào thì chỉ domain đó hoạt động, không cần khai báo thêm gì. Domain gốc `kruzetech.dev` (nếu cần `www.kruzetech.dev` redirect) thì cấu hình tay riêng, không qua script này.
- Không cần phân biệt domain có websocket hay không: config tự route request có header `Upgrade` sang `@websocket` (timeout 600s), còn REST giữ 60s. Domain nào cũng dùng chung 1 lệnh.

---

### Thêm node backend

```bash
# Nhớ thêm đúng file theo cluster (cluster-prod.conf hoặc cluster-dev.conf)
echo "server 10.10.10.14:30080;" >> /etc/nginx/backends/cluster-prod.conf
nginx -t && systemctl reload nginx
```

---

### Remove domain

```bash
DOMAIN=nexus.kruzetech.dev

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
sudo add-domain ecommerce-api-gateway.thang2k6adu.xyz cluster-dev
```

Commit rồi đẩy lên. Chờ gitops là xong.