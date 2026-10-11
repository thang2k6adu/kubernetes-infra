#!/bin/bash

# Chạy trên VPS (GCP). Card mạng public là ens4 (kiểm tra bằng: ip a).
# Worker chạy LiveKit: 10.10.10.12 (qua VPN wg0).

# ==========================================
# CẢNH BÁO: KHÔNG chạy 2 lệnh flush dưới đây
# ==========================================
# VPS đang có rule NAT khác (vd: tcp 8022 -> 10.10.10.11:8022 để SSH vào worker).
# -F xoá SẠCH mọi rule trong chain => mất luôn rule 8022 (và mọi rule của dịch vụ khác).
#
#   sudo iptables -t nat -F PREROUTING     # <-- XOÁ rule 8022
#   sudo iptables -t nat -F POSTROUTING    # <-- XOÁ rule 8022
#
# Thay bằng cách "thêm nếu chưa có" bên dưới: -C kiểm tra rule đã tồn tại chưa,
# chưa có mới -A. Chạy lại nhiều lần không bị trùng, không đụng rule cũ.

# Bật ip routing (ghi vào sysctl.d, chạy lại không bị ghi trùng)
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/98-ip-forward.conf
sudo sysctl --system

# 1. Forward nửa dưới (từ 50000 đến 51819)
# 51820 là WireGuard (wg0) nên BỎ QUA, không forward
sudo iptables -t nat -C PREROUTING -i ens4 -p udp -m udp --dport 50000:51819 -j DNAT --to-destination 10.10.10.12 2>/dev/null \
  || sudo iptables -t nat -A PREROUTING -i ens4 -p udp -m udp --dport 50000:51819 -j DNAT --to-destination 10.10.10.12
sudo iptables -t nat -C POSTROUTING -p udp -m udp -d 10.10.10.12 --dport 50000:51819 -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -p udp -m udp -d 10.10.10.12 --dport 50000:51819 -j MASQUERADE

# 2. Forward nửa trên (từ 51821 đến 60000)
sudo iptables -t nat -C PREROUTING -i ens4 -p udp -m udp --dport 51821:60000 -j DNAT --to-destination 10.10.10.12 2>/dev/null \
  || sudo iptables -t nat -A PREROUTING -i ens4 -p udp -m udp --dport 51821:60000 -j DNAT --to-destination 10.10.10.12
sudo iptables -t nat -C POSTROUTING -p udp -m udp -d 10.10.10.12 --dport 51821:60000 -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -p udp -m udp -d 10.10.10.12 --dport 51821:60000 -j MASQUERADE

# Kiểm tra lại các rule (phải thấy cả rule 8022 cũ lẫn rule UDP mới)
sudo iptables -t nat -S

# ==========================================
# LƯU VĨNH VIỄN iptables (bắt buộc)
# ==========================================
# iptables chỉ nằm trong RAM: không lưu thì REBOOT VPS là MẤT sạch rule, LiveKit hết media.
# VPS đã cài sẵn iptables-persistent (nếu máy mới: sudo apt install -y iptables-persistent).
# Lệnh này lưu toàn bộ rule hiện tại (gồm cả 8022) vào /etc/iptables/rules.v4.
sudo netfilter-persistent save

# ==========================================
# Tối ưu Connection Tracking
# ==========================================
# Ghi vào file riêng trong sysctl.d: tự nạp lại khi reboot,
# chạy lại script không bị ghi trùng (khác với `tee -a /etc/sysctl.conf`).
# - nf_conntrack_max: giúp server chịu được nhiều connections hơn
# - udp_timeout / udp_timeout_stream = 300: UDP không có packet trong 5' mới coi là disconnect.
#   Để thấp dễ bị drop, kernel nghĩ connection đã chết.
cat <<EOF | sudo tee /etc/sysctl.d/99-livekit.conf
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 300
net.netfilter.nf_conntrack_udp_timeout_stream = 300
EOF

sudo sysctl --system
