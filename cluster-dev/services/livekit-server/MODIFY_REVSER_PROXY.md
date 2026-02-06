vào backend sửa lại (VPS)

Lấy ip vpn (trên server)
ansible-inventory -i ~/k3s-inventory/hosts.ini --list \
| jq -r '
._meta.hostvars
| to_entries[]
| select(.value.ansible_user=="thang2k6adu")
| "server \(.value.vpn_ip):30443;"
'

phải ra

server 10.10.20.11:30443;
server 10.10.20.12:30443;
server 10.10.20.13:30443;

đổi thành

server 10.10.20.11:7880;
server 10.10.20.12:7880;
server 10.10.20.13:7880;

lên vps
sudo nano /etc/nginx/backends/cluster-dev-livekit.conf

paste 
server 10.10.20.11:7880;
server 10.10.20.12:7880;
server 10.10.20.13:7880;

vào

sudo nano /etc/nginx/conf.d/ingress_upstream.conf

thêm vào cuối

upstream cluster-dev-livekit {
    least_conn;
    include /etc/nginx/backends/cluster-dev-livekit.conf;
}

vào 
 sudo nano /etc/nginx/sites-available/livekit.thang2k6adu.xyz

sửa hết https://cluster-dev thành (mặc định livekit ko có tls nên ko có https)

proxy_pass http://cluster-dev-livekit;

restart

sudo nginx -t
sudo systemctl restart nginx