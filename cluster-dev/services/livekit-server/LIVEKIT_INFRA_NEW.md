sudo iptables -t nat -F PREROUTING
sudo iptables -t nat -F POSTROUTING

# Forward nửa dưới (từ 50000 đến sát vách 51819)
sudo iptables -t nat -A PREROUTING -i ens5 -p udp -m udp --dport 50000:51819 -j DNAT --to-destination 10.10.20.12

# Forward nửa trên (từ 51821 đến 60000)
sudo iptables -t nat -A PREROUTING -i ens5 -p udp -m udp --dport 51821:60000 -j DNAT --to-destination 10.10.20.12

# Masquerade cho nửa dưới
sudo iptables -t nat -A POSTROUTING -p udp -m udp -d 10.10.20.12 --dport 50000:51819 -j MASQUERADE

# Masquerade cho nửa trên
sudo iptables -t nat -A POSTROUTING -p udp -m udp -d 10.10.20.12 --dport 51821:60000 -j MASQUERADE

sudo iptables -t nat -L -n -v

 # Tăng x10 lần giới hạn theo dõi kết nối (Chống rớt gói khi đông user)
sudo sysctl -w net.netfilter.nf_conntrack_max=1048576

# WebRTC UDP đôi khi bị ngắt quãng, tăng timeout lên 5 phút để kết nối không bị đứt gánh giữa chừng
sudo sysctl -w net.netfilter.nf_conntrack_udp_timeout=300
sudo sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=300
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 300
net.netfilter.nf_conntrack_udp_timeout_stream = 300


sau này có nhiều node thì phân lô ra là được
node 1 50-55k node 2 55k - 60k