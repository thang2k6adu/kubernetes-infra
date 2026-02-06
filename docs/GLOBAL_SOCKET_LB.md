# Cấu hình WebSocket (Upgrade Header) cho Nginx – Global

## 1. Mở file cấu hình chính của Nginx

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

include /etc/nginx/conf.d/*.conf;
include /etc/nginx/sites-enabled/*;
```

---

## 2. Sửa template file server (Virtual Host)

Tìm đoạn cấu hình cũ:

```nginx
location / {
    proxy_pass https://cluster-dev;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

---

## 3. Sửa thành cấu hình mới (thêm WebSocket headers)

```nginx
location / {
    proxy_pass https://cluster-dev;

    # Thêm cấu hình WebSocket
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

---

## 4. Áp dụng cho tất cả các `location` có `proxy_pass`

Ví dụ với `location /api/`:

```nginx
location /api/ {
    proxy_pass https://cluster-dev;

    # Thêm cấu hình WebSocket
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

---

## 5. Kiểm tra và reload Nginx

```bash
nginx -t
systemctl reload nginx
```

Nếu không có lỗi → cấu hình hợp lệ.

---

## 📌 Giải thích kỹ thuật (có cơ sở)

WebSocket cần 2 header bắt buộc:

> `Upgrade: websocket`
> `Connection: Upgrade`
