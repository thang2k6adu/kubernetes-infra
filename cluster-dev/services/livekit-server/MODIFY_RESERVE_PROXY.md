# Hướng dẫn cấu hình Nginx Backend cho LiveKit (VPS)

## Bước 1: Lấy IP VPN từ server

Chạy lệnh sau trên server:
```bash
ansible-inventory -i ~/k3s-inventory/hosts.ini --list \
| jq -r '
._meta.hostvars
| to_entries[]
| select(.value.ansible_user=="thang2k6adu")
| "server \(.value.vpn_ip):30443;"
'
```

Kết quả phải ra:
```
server 10.10.10.11:30443;
server 10.10.10.12:30443;
```

## Bước 2: Đổi port thành 7880

Đổi thành:
```
server 10.10.10.11:7880;
server 10.10.10.12:7880;
```

## Bước 3: Cấu hình backend trên VPS
```bash
sudo nano /etc/nginx/backends/cluster-prod-livekit.conf
```

Paste nội dung:
```nginx
server 10.10.10.11:7880;
server 10.10.10.12:7880;
```

## Bước 3.1: Cấu hình upstream
```bash
sudo nano /etc/nginx/conf.d/ingress_upstream.conf
```

Thêm nội dung:
```nginx
upstream cluster-prod-livekit {
    least_conn;
    include /etc/nginx/backends/cluster-prod-livekit.conf;
}
```

## Bước 4: Sửa file site config
```bash
sudo nano /etc/nginx/sites-available/livekit.kruzetech.dev
```

Sửa hết `https://cluster-prod` thành (mặc định LiveKit không có TLS nên không có https):
```nginx
proxy_pass http://cluster-prod-livekit;
```

## Bước 6: Restart Nginx

Kiểm tra cấu hình:
```bash
sudo nginx -t
```

Restart Nginx:
```bash
sudo systemctl restart nginx
```