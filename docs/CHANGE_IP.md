when change ip, k3s cannot re-advertise it's ip to other nodes

sudo mkdir -p /etc/rancher/k3s

sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'EOF'
node-ip: 192.168.1.50
advertise-address: 192.168.1.50
tls-san:
  - 192.168.1.50
EOF

sudo systemctl restart k3s