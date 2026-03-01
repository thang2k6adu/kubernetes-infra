sudo iptables -t nat -A PREROUTING -p udp --dport 50000:60000 -j DNAT --to-destination 10.10.20.12

 sudo iptables -t nat -A POSTROUTING -p udp --dport 50000:60000 -d 10.10.20.12 -j MASQUERADE

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