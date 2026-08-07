# Hướng Dẫn Cài Đặt WireGuard VPN và Nginx Reverse Proxy cho K3s Cluster

## Sơ Đồ Kiến Trúc

```
CLIENT (trình duyệt)
    |
    | http://domain (80) hoặc https://domain (443)
    v
[VPS Public IP + Nginx + Certbot]
    |
    | proxy_pass qua WireGuard VPN
    v
[WireGuard tunnel 10.10.10.0/24]
    |
    v
[NodePort Ingress NGINX trên các node K3s]
    | (30080 cho HTTP, 30443 cho HTTPS)
    |
    v
[Ingress Controller]
    |
    v
[Service trong cluster]
    |
    v
[Pod (app, dashboard, v.v.)]
```

---

## Fix lỗi máy master (lỗi quyền)

```bash
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

---

## Phần 1: Cài Đặt WireGuard

### 1.1. Cài đặt WireGuard trên tất cả server (trên master)

**Tạo file playbook:**

```bash
nano ~/k3s-inventory/install-wireguard.yml
```

**Nội dung `install-wireguard.yml`:**

```yaml
- name: Install WireGuard on all servers
  hosts: all
  become: true
  tasks:
    - name: Update apt
      apt:
        update_cache: yes

    - name: Install wireguard
      apt:
        name: wireguard
        state: present
```

**Chạy playbook:**

```bash
ansible-playbook -i ~/k3s-inventory/hosts.ini ~/k3s-inventory/install-wireguard.yml
```

---

### 1.2. Tạo key cho các máy

**Tạo file playbook:**

```bash
nano ~/k3s-inventory/gen-keys.yml
```

**Nội dung `gen-keys.yml`:**

```yaml
- name: Generate WireGuard keys
  hosts: all
  become: true
  tasks:
    - name: Create wireguard dir
      file:
        path: /etc/wireguard
        state: directory
        mode: 0700

    - name: Generate private key
      shell: wg genkey > /etc/wireguard/privatekey
      args:
        creates: /etc/wireguard/privatekey

    - name: Generate public key
      shell: cat /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
      args:
        creates: /etc/wireguard/publickey
```

**Chạy playbook:**

```bash
ansible-playbook -i ~/k3s-inventory/hosts.ini ~/k3s-inventory/gen-keys.yml
```

**Lấy public key của các máy:**

```bash
ansible -i ~/k3s-inventory/hosts.ini all -b -m shell -a "cat /etc/wireguard/publickey"
```

**Check file hosts:**

```bash
cat ~/k3s-inventory/hosts.ini
```

---

### 1.3. Cài WireGuard trên VPS

**Cài đặt (nếu chỉ thêm cluster mới thì cái này bỏ qua):**

```bash
sudo apt update
sudo apt install wireguard -y
```

**Tạo key (nếu chỉ thêm cluster mới thì cái này bỏ qua):**

```bash
sudo sh -c 'umask 077; wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey'
```

**Lấy public key và lưu vào:**

```bash
sudo cat /etc/wireguard/publickey
```

Ví dụ: `Q/avQ4fi7Dd21Dh0Ex/Rwp/YjIMfgs2Q7sxRv94DRFE=`

---

### 1.4. Mục tiêu cấu hình

**VPS:** (chứa peer của tất cả node)
```
/etc/wireguard/wg0.conf
```

**Mỗi node:** (kết nối về VPS)
```
/etc/wireguard/wg0.conf
```

---

### 1.5. Cập nhật hosts.ini với thông tin VPN

**Lấy IP master (sửa vpn subnet nếu thêm cluster mới):**

```bash
VPN_NET="10.10.10"
MASTER=$(awk '/^\[master\]/{getline; print $1}' ~/k3s-inventory/hosts.ini)
```

**Lấy public key map theo IP:**

```bash
ansible -i ~/k3s-inventory/hosts.ini master:workers -b \
  -m shell -a "cat /etc/wireguard/publickey" --one-line \
  | awk '{print $1, $NF}' > /tmp/wg_keys.map

awk -v master="$MASTER" -v vpn_net="$VPN_NET" '
BEGIN {
    vpn_master=11
    vpn_worker=12

    while ((getline < "/tmp/wg_keys.map") > 0) {
        keys[$1] = $2
    }
}

/^\[master\]/ {
    print
    section="master"
    next
}

/^\[workers\]/ {
    print
    section="workers"
    next
}

/^\[/ {
    print
    next
}

NF > 0 {
    ip = $1
    line = $0

    # Xóa giá trị cũ nếu có
    gsub(/[[:space:]]+vpn_ip=[^[:space:]]+/, "", line)
    gsub(/[[:space:]]+wg_public_key=[^[:space:]]+/, "", line)

    if (ip in keys) {
        if (section == "master") {
            printf "%s vpn_ip=%s.%d wg_public_key=%s\n",
                   line, vpn_net, vpn_master, keys[ip]
            vpn_master++
        }
        else if (section == "workers") {
            printf "%s vpn_ip=%s.%d wg_public_key=%s\n",
                   line, vpn_net, vpn_worker, keys[ip]
            vpn_worker++
        }
        else {
            print line
        }
    } else {
        print line
    }

    next
}

{
    print
}
' ~/k3s-inventory/hosts.ini > ~/k3s-inventory/hosts.tmp.ini
```

```bash
rm -f /tmp/wg_keys.map
mv ~/k3s-inventory/hosts.tmp.ini ~/k3s-inventory/hosts.ini
```

**Check kết quả:**

```bash
cat ~/k3s-inventory/hosts.ini
```

**Phải ra:**

```ini
[master]
192.168.0.50 ansible_user=thang2k6adu ansible_port=8022 worker_ip=192.168.0.50 iface=ens33 vpn_ip=10.10.10.11 wg_public_key=5bxuSFwlbtwuwHwwR7lT/z8lYzavzjyZrGEyETSuwSU=

[workers]
192.168.0.51 ansible_user=thang2k6adu ansible_port=8022 worker_ip=192.168.0.51 iface=ens33 vpn_ip=10.10.10.12 wg_public_key=VlyT8xTQnKZoBbV9K5Ffc8Qw/lN6HGLL8oF4h9C+ERg=
192.168.0.52 ansible_user=thang2k6adu ansible_port=8022 worker_ip=192.168.0.52 iface=ens33 vpn_ip=10.10.10.13 wg_public_key=9QS1wLfjqHDaATHjgfzC4YrvhCxQcLWp9teVYEZn9n4=
```

---

### 1.6. Khai báo thông tin VPS

**Sửa hosts.ini:**

```bash
nano ~/k3s-inventory/hosts.ini
```

**Thêm (nhớ thay ip public, user và public key, ip vpn của vps):**

```ini
[vps]
18.143.115.106 ansible_user=ubuntu vpn_ip=10.10.10.1 wg_public_key=Q/avQ4fi7Dd21Dh0Ex/Rwp/YjIMfgs2Q7sxRv94DRFE=
```

---

### 1.7. Tạo wg0.conf trên các node

**Tạo playbook:**

```bash
nano ~/k3s-inventory/gen-node-wg.yml
```

**Nội dung `gen-node-wg.yml`:**

```yaml
- name: Generate wg0.conf for nodes
  hosts: master:workers
  become: true
  vars:
    vps_ip: "{{ hostvars[groups['vps'][0]].inventory_hostname }}"
    vps_pubkey: "{{ hostvars[groups['vps'][0]].wg_public_key }}"
    vpn_cidr: "10.10.10.0/24"  # đổi subnet tại đây khi thêm cluster mới
  tasks:
    - name: Read private key
      shell: cat /etc/wireguard/privatekey
      register: node_priv

    - name: Create wg0.conf
      copy:
        dest: /etc/wireguard/wg0.conf
        mode: 0600
        content: |
          [Interface]
          Address = {{ vpn_ip }}/24
          PrivateKey = {{ node_priv.stdout }}

          [Peer]
          PublicKey = {{ vps_pubkey }}
          Endpoint = {{ vps_ip }}:51820
          AllowedIPs = {{ vpn_cidr }}
          PersistentKeepalive = 25
```

**Chạy playbook:**

```bash
ansible-playbook -i ~/k3s-inventory/hosts.ini ~/k3s-inventory/gen-node-wg.yml
```

**Check thử 1 node (master):**

```bash
sudo cat /etc/wireguard/wg0.conf
```

**Phải ra:**

```ini
[Interface]
Address = 10.10.10.11/24
PrivateKey = 2MpNSUhR6Hb5VOPmwJPR4IE3M0FxB3Ib1QEARoJNnHY=

[Peer]
PublicKey = JKL1bfmnfZfoS/QyQKIVW5mgENgNh4CyhlYi2ObqVUs=
Endpoint = 13.229.60.179:51820
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25
```

---

### 1.8. Gen file wg0 cho VPS

**Tạo playbook:**

```bash
nano ~/k3s-inventory/gen-vps-wg.yml
```

**Nội dung `gen-vps-wg.yml`:**

```yaml
- name: Generate VPS wg0.conf
  hosts: localhost
  vars:
    vps_private_key: "PASTE_PRIVATE_KEY_VPS_HERE"
    vpn_subnets:
      - 10.10.10.1/24
      - 10.10.20.1/24   # cluster mới, thêm mới thì thêm vào
  tasks:
    - name: Build VPS config
      copy:
        dest: /home/thang2k6adu/k3s-inventory/wg0.vps.conf
        content: |
          [Interface]
          Address = {{ vpn_subnets | join(', ') }}
          ListenPort = 51820
          PrivateKey = {{ vps_private_key }}

          {% for host in groups['master'] + groups['workers'] %}
          [Peer]
          PublicKey = {{ hostvars[host].wg_public_key }}
          AllowedIPs = {{ hostvars[host].vpn_ip }}/32

          {% endfor %}
```

**Chạy playbook:**

```bash
ansible-playbook -i ~/k3s-inventory/hosts.ini ~/k3s-inventory/gen-vps-wg.yml
```

**Check:**

```bash
cat ~/k3s-inventory/wg0.vps.conf
```

```ini
[Interface]
Address = 10.10.10.1/24, 10.10.20.1/24
ListenPort = 51820
PrivateKey = PASTE_PRIVATE_KEY_VPS_HERE

[Peer]
PublicKey = 2hMqEzFG3zxu3Fomz/JjxXz3a+Hl5Cytp33Hk/44IXk=
AllowedIPs = 10.10.20.11/32

[Peer]
PublicKey = 7t1tUuZVNs0ZIkQFCYIrj/fNG+7jrE7AathPVIZQSA4=
AllowedIPs = 10.10.20.12/32

[Peer]
PublicKey = 9q5GuZI2bQ00AZdB/3dAHTp4VSCC8Feg6vjxgKqCjmk=
AllowedIPs = 10.10.20.13/32
```

---

### 1.9. Cấu hình wg0.conf trên VPS

**Lên VPS, lấy private key:**

```bash
sudo cat /etc/wireguard/privatekey
```

**Tạo file config:**

```bash
sudo nano /etc/wireguard/wg0.conf
```

**Nội dung:**

```ini
[Interface]
Address = 10.10.10.1/24
ListenPort = 51820
PrivateKey = PASTE_PRIVATE_KEY_VPS_HERE

[Peer]
PublicKey = 5bxuSFwlbtwuwHwwR7lT/z8lYzavzjyZrGEyETSuwSU=
AllowedIPs = 10.10.10.11/32

[Peer]
PublicKey = VlyT8xTQnKZoBbV9K5Ffc8Qw/lN6HGLL8oF4h9C+ERg=
AllowedIPs = 10.10.10.12/32

[Peer]
PublicKey = 9QS1wLfjqHDaATHjgfzC4YrvhCxQcLWp9teVYEZn9n4=
AllowedIPs = 10.10.10.13/32
```

**Nếu thêm cluster mới thì chỉ thêm Address mới + peer mới như dưới đây:**

```bash
sudo nano /etc/wireguard/wg0.conf
```

**Nội dung:**

```ini
[Interface]
Address = 10.10.10.1/24, 10.10.20.1/24  # thêm cluster mới
ListenPort = 51820
PrivateKey = +CB2hgASvIul0UBtGsBbgRxQxPB1Ton/qHE4TMUZt04=

[Peer]
PublicKey = 7GPiM+Ju79MBDVJJvL5uGHAJM71VTtZsGq2pQZlC4iQ=
AllowedIPs = 10.10.10.11/32

[Peer]
PublicKey = r3Gh8n6lmfWbSWykd766yQ27tKEt2PuWIMhxaDK7km4=
AllowedIPs = 10.10.10.12/32

# Thêm mới
[Peer]
PublicKey = 5bxuSFwlbtwuwHwwR7lT/z8lYzavzjyZrGEyETSuwSU=
AllowedIPs = 10.10.20.11/32

[Peer]
PublicKey = VlyT8xTQnKZoBbV9K5Ffc8Qw/lN6HGLL8oF4h9C+ERg=
AllowedIPs = 10.10.20.12/32

[Peer]
PublicKey = 9QS1wLfjqHDaATHjgfzC4YrvhCxQcLWp9teVYEZn9n4=
AllowedIPs = 10.10.20.13/32
```

---

### 1.10. Bật IP forward trên VPS

```bash
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 1.10.1. Forward SSH (BONUS)

```bash
# Destination nat, chuyển từ ip vps sang ip node
sudo iptables -t nat -A PREROUTING \
    -p tcp --dport 8022 \
    -j DNAT --to-destination 10.10.10.11:8022

# Forward traffic từ vps sang node, mặc định linux có firewall cấm
sudo iptables -A FORWARD \
    -p tcp -d 10.10.10.11 --dport 8022 \
    -j ACCEPT

# Masquerade  (source nat), tránh node trả thẳng client mà ko qua vps, connect tới 18.xx mà 10.xx trả là sai
sudo iptables -t nat -A POSTROUTING \
    -d 10.10.10.11 \
    -p tcp --dport 8022 \
    -j MASQUERADE


# Check
sudo iptables -t nat -L -n -v --line-numbers
sudo iptables -L FORWARD -n -v --line-numbers
```

**Mở port (EC2 thì lên trang) (51820 UDP)**

---

### 1.11. Khởi động WireGuard trên VPS

```bash
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
sudo systemctl status wg-quick@wg0
```

**Restart nếu cần:**

```bash
nano ~/k3s-inventory/restart-wireguard.yml
```

```yaml
- name: Restart WireGuard on all nodes
  hosts: master:workers
  become: true
  tasks:
    - name: Restart wg-quick@wg0
      systemd:
        name: wg-quick@wg0
        state: restarted
        enabled: yes

    - name: Wait for WireGuard to stabilize
      pause:
        seconds: 3

    - name: Show WireGuard status
      command: wg
      register: wg_status

    - name: Show wg0 interface
      command: ip a show wg0
      register: ip_status

    - name: Print wg status
      debug:
        msg: "{{ wg_status.stdout }}"

    - name: Print ip status
      debug:
        msg: "{{ ip_status.stdout }}"
```

**Chạy:**

```bash
ansible-playbook -i ~/k3s-inventory/hosts.ini ~/k3s-inventory/restart-wireguard.yml
```

**Trên VPS:**

```bash
sudo systemctl restart wg-quick@wg0
```

**Check:**

```bash
sudo wg
ip a show wg0
```

---

### 1.12. Khởi động WireGuard trên các node (trên LAN master)

**Tạo playbook:**

```bash
nano ~/k3s-inventory/start-wireguard.yml
```

**Nội dung `start-wireguard.yml`:**

```yaml
- name: Start WireGuard on all hosts
  hosts: master:workers
  become: true
  tasks:
    - name: Enable wg-quick@wg0
      systemd:
        name: wg-quick@wg0
        enabled: yes

    - name: Start wg-quick@wg0
      systemd:
        name: wg-quick@wg0
        state: started

    - name: Show WireGuard status
      command: wg
      register: wg_status

    - name: Show wg0 interface
      command: ip a show wg0
      register: ip_status

    - name: Print wg status
      debug:
        msg: "{{ wg_status.stdout }}"

    - name: Print ip status
      debug:
        msg: "{{ ip_status.stdout }}"
```

**Chạy:**

```bash
ansible-playbook -i ~/k3s-inventory/hosts.ini ~/k3s-inventory/start-wireguard.yml
```

**Mở port các node:**

```bash
nano ~/k3s-inventory/open-wireguard-port.yml
```

```yaml
- name: Open WireGuard UDP port 51820
  hosts: master:workers
  become: true
  tasks:
    - name: Ensure ufw is installed
      apt:
        name: ufw
        state: present
        update_cache: yes

    - name: Allow WireGuard port 51820/udp
      ufw:
        rule: allow
        port: 51820
        proto: udp

    - name: Enable ufw
      ufw:
        state: enabled
        policy: allow

    - name: Show ufw status
      command: ufw status
      register: ufw_status

    - debug:
        msg: "{{ ufw_status.stdout }}"
```

**Chạy:**

```bash
ansible-playbook -i ~/k3s-inventory/hosts.ini ~/k3s-inventory/open-wireguard-port.yml
```

**Test trên node (nào cũng được), nếu fail hãy mở port vps:**

```bash
ping 10.10.10.1
```

---