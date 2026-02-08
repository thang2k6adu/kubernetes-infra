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
server 10.10.20.11:30443;
server 10.10.20.12:30443;
server 10.10.20.13:30443;
```

## Bước 2: Đổi port thành 7880

Đổi thành:
```
server 10.10.20.11:7880;
server 10.10.20.12:7880;
server 10.10.20.13:7880;
```

## Bước 3: Cấu hình backend trên VPS
```bash
sudo nano /etc/nginx/backends/cluster-dev-livekit.conf
```

Paste nội dung:
```nginx
server 10.10.20.11:7880;
server 10.10.20.12:7880;
server 10.10.20.13:7880;
```

## Bước 4: Sửa file site config
```bash
sudo nano /etc/nginx/sites-available/livekit.thang2k6adu.xyz
```

Sửa hết `https://cluster-dev` thành (mặc định LiveKit không có TLS nên không có https):
```nginx
proxy_pass http://cluster-dev-livekit;
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