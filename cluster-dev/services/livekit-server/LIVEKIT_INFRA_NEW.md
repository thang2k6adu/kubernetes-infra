#!/bin/bash

# Xóa rule NAT cũ
sudo iptables -t nat -F PREROUTING
sudo iptables -t nat -F POSTROUTING

# Bật ip routing
sudo sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf \
&& echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf \
&& sudo sysctl -p

# 1. Forward nửa dưới (từ 50000 đến 51819)
sudo iptables -t nat -A PREROUTING -i ens5 -p udp -m udp --dport 50000:51819 -j DNAT --to-destination 10.10.10.12
sudo iptables -t nat -A POSTROUTING -p udp -m udp -d 10.10.10.12 --dport 50000:51819 -j MASQUERADE

# 2. Forward nửa trên (từ 51821 đến 60000)
sudo iptables -t nat -A PREROUTING -i ens5 -p udp -m udp --dport 51821:60000 -j DNAT --to-destination 10.10.10.12
sudo iptables -t nat -A POSTROUTING -p udp -m udp -d 10.10.10.12 --dport 51821:60000 -j MASQUERADE

# Kiểm tra lại các rule
sudo iptables -t nat -L -n -v

# ==========================================
# Tối ưu Connection Tracking
# ==========================================
#giúp server chị tải nhiều connections hơn
sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
#tăng timeout, udp ko packet trong 5' mới disconnect
sudo sysctl -w net.netfilter.nf_conntrack_udp_timeout=300
#Tăng stream timeout, để thấp dễ bị drop, kernel nghĩ connection die
sudo sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=300

# Ghi vĩnh viễn vào file cấu hình
cat <<EOF | sudo tee -a /etc/sysctl.conf
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 300
net.netfilter.nf_conntrack_udp_timeout_stream = 300
EOF

sudo sysctl -p