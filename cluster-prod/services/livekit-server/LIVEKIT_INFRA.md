# IPVS + Keepalived Configuration Guide for LiveKit (fwmark Approach)

## Architecture Explanation

### Problem to Solve

LiveKit requires 2 types of connections:

1. **TCP (Signaling) - Port 7880/7881:**
   - Client connects to establish session
   - Nginx reverse proxy can handle this
   
2. **UDP (Media/RTP) - Port 50000-60000:**
   - Actual audio, video transmission
   - **Nginx CANNOT reverse proxy UDP**
   - Need alternative solution → **IPVS with fwmark**

---

### Why fwmark Instead of Port-by-Port?

**Old approach (10,001 virtual_server):**
```
3 backends × 10,001 ports = 30,003 health checks every 5 seconds
```

**New approach (1 fwmark virtual_server):**
```
3 backends × 1 fwmark = 3 health checks every 5 seconds
```

**Performance improvement: 99.99% reduction in health checks**

---

### Role of Each Component

| Component | Role | Protocol |
|-----------|------|----------|
| **Nginx** | Reverse proxy signaling | TCP 7880/7881 |
| **iptables** | Mark UDP port range with fwmark | UDP 50000-60000 |
| **IPVS** | Load balance marked traffic | fwmark 1 |
| **Keepalived** | Health check + Manage IPVS | TCP 7880 (check) |

**What Keepalived does:**
- Automatically create IPVS rules using fwmark
- Health check TCP port 7880 every 5 seconds (only once per backend)
- Automatically remove dead pods from IPVS table
- Automatically add pods back when they come alive

---

### Data Flow Diagram
```
┌─────────────────────────────────────────────────────────┐
│                      SIGNALING (TCP)                     │
└─────────────────────────────────────────────────────────┘

Client
  |
  | TCP 7880/7881 (signaling)
  v
VPS (Nginx Reverse Proxy)
  |
  ├─> LiveKit Pod 1 (10.10.20.11:7880)
  ├─> LiveKit Pod 2 (10.10.20.12:7880)
  └─> LiveKit Pod 3 (10.10.20.13:7880)


┌─────────────────────────────────────────────────────────┐
│                    MEDIA (UDP)                          │
└─────────────────────────────────────────────────────────┘

Client
  |
  | UDP 50000-60000 (media/RTP)
  v
VPS (iptables → mark fwmark 1)
  |
  v
IPVS (Load Balancer using fwmark 1)
  |    ↑
  |    └─ Keepalived (Health Check TCP 7880 - ONLY 3 checks)
  |
  ├─> LiveKit Pod 1 (10.10.20.11:50000-60000)
  ├─> LiveKit Pod 2 (10.10.20.12:50000-60000)
  └─> LiveKit Pod 3 (10.10.20.13:50000-60000)
```

---

### How fwmark Works

```
1. Client sends UDP packet to 13.212.50.46:50034
                ↓
2. iptables marks packet: fwmark = 1
                ↓
3. IPVS sees fwmark 1 → applies load balancing
                ↓
4. Packet forwarded to: 10.10.20.11:50034 (or 12, or 13)
```

**Key advantage:** All 10,001 ports (50000-60000) share the same IPVS rule.

---

## Part 1: Installation & Basic Configuration

### Step 1: Install packages
```bash
sudo apt update
sudo apt install -y ipvsadm keepalived iptables-persistent iproute2
```

---

### Step 2: Load kernel modules
```bash
sudo modprobe ip_vs
sudo modprobe ip_vs_sh
sudo modprobe ip_vs_rr
sudo modprobe nf_conntrack
```

**Auto-load on reboot:**
```bash
cat <<EOF | sudo tee /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_sh
ip_vs_rr
nf_conntrack
EOF
```

**Check:**
```bash
lsmod | grep ip_vs
```

---

### Step 3: Enable IP forwarding
```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

**Save permanently:**
```bash
sudo sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf && echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf && sudo sysctl -p
```

---

## Part 2: iptables Configuration (fwmark Setup)

### Step 4: Create iptables rules for fwmark

**Create script to setup fwmark rules:**
```bash
sudo nano /usr/local/bin/setup-fwmark.sh
```

**Script content:**
```bash
#!/bin/bash

PUBLIC_IP="172.31.36.102"
START_PORT=50000
END_PORT=60000
FWMARK=1
VPN_PORT=51820

echo "Setting up fwmark rules for UDP port range $START_PORT-$END_PORT..."

# Clear existing mangle rules for this fwmark
iptables -t mangle -D PREROUTING -d $PUBLIC_IP -p udp --dport $START_PORT:$END_PORT -j MARK --set-mark $FWMARK 2>/dev/null
iptables -t mangle -D PREROUTING -d $PUBLIC_IP -p udp --dport $VPN_PORT -j RETURN 2>/dev/null

# return ISTEAD OF mark
iptables -t mangle -A PREROUTING -d $PUBLIC_IP -p udp --dport $VPN_PORT -j RETURN

# Add new rule
iptables -t mangle -A PREROUTING -d $PUBLIC_IP -p udp --dport $START_PORT:$END_PORT -j MARK --set-mark $FWMARK

echo "✓ fwmark rule created"
echo ""
echo "Verify with: sudo iptables -t mangle -L PREROUTING -n -v"
```

**Grant execution permission:**
```bash
sudo chmod +x /usr/local/bin/setup-fwmark.sh
```

**Run the script:**
```bash
sudo /usr/local/bin/setup-fwmark.sh
```

---

### Step 5: Save iptables rules permanently

**Save current rules:**
```bash
sudo netfilter-persistent save
```

**Or manually:**
```bash
sudo iptables-save > /etc/iptables/rules.v4
```

**Delete certain rule:**
```bash
sudo iptables -t mangle -D PREROUTING -d 13.212.50.46 -p udp -m udp --dport 50000:60000 -j MARK --set-mark 1
```

**Verify fwmark rule:**
```bash
sudo iptables -t mangle -L PREROUTING -n -v
```

**Expected output:**
```
Chain PREROUTING (policy ACCEPT)
target     prot opt in     out     source      destination
MARK       udp  --  *      *       0.0.0.0/0   13.212.50.46   udp dpts:50000:60000 MARK set 0x1
```

---

## Part 3: Backend Nodes Configuration

### Step 6: Create backend list file

This file contains the list of LiveKit pods IP addresses:
```bash
sudo mkdir -p /etc/nginx/backends
sudo nano /etc/nginx/backends/cluster-dev-livekit.conf
```

**Sample content:**
```nginx
server 10.10.20.11:7880;
server 10.10.20.12:7880;
server 10.10.20.13:7880;
```

**Note:** 
- Format: `server <VPN_IP>:7880;`
- Port 7880 is LiveKit's signaling port
- Each line ends with `;`

---

## Part 4: Keepalived Configuration (fwmark Approach)

### Step 7: Create script to generate Keepalived config with fwmark
```bash
sudo nano /usr/local/bin/gen-keepalived-fwmark.sh
```

**Script content:**
```bash
#!/bin/bash

FWMARK=1
BACKEND_FILE="/etc/nginx/backends/cluster-dev-livekit.conf"
OUTPUT="/etc/keepalived/keepalived.conf"

# Extract backend IPs from config file
BACKENDS=$(awk '{print $2}' $BACKEND_FILE | sed 's/;//g' | cut -d: -f1)

if [ -z "$BACKENDS" ]; then
    echo "❌ No backends found in $BACKEND_FILE"
    exit 1
fi

echo "✓ Found backends:"
echo "$BACKENDS"
echo ""

# Generate Keepalived config
cat > $OUTPUT <<EOF
global_defs {
   router_id LIVEKIT_LVS
}

# ──────────────────────────────────────────────────────
# Virtual Server using fwmark (covers port 50000-60000)
# ──────────────────────────────────────────────────────
virtual_server fwmark $FWMARK {
    delay_loop 5        # Health check every 5 seconds
    lb_algo rr          # Round Robin
    lb_kind NAT         # NAT mode
EOF

# Add real servers with health check
for ip in $BACKENDS; do
cat >> $OUTPUT <<EOF
    real_server $ip 0 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 5
            retry 5
            delay_before_retry 3
        }
    }
EOF
done

# Close virtual_server block
echo "}" >> $OUTPUT

echo ""
echo "✓ Keepalived config created at: $OUTPUT"
echo "✓ Using fwmark: $FWMARK"
echo "✓ Backend servers: $(echo "$BACKENDS" | wc -l)"
echo "✓ Health checks per cycle: $(echo "$BACKENDS" | wc -l) (instead of $(($(echo "$BACKENDS" | wc -l) * 10001)))"
```

**Grant execution permission:**
```bash
sudo chmod +x /usr/local/bin/gen-keepalived-fwmark.sh
```

---

### Step 8: Generate config and start Keepalived
```bash
# 1. Generate Keepalived config
sudo /usr/local/bin/gen-keepalived-fwmark.sh

# 2. Check syntax
sudo keepalived -t -f /etc/keepalived/keepalived.conf

# 3. Enable service
sudo systemctl enable keepalived

# 4. Start Keepalived
sudo systemctl stop keepalived
sudo systemctl start keepalived
sudo systemctl restart keepalived


# 5. Check status
sudo systemctl status keepalived
```

---

## Part 5: Checking & Troubleshooting

### Check IPVS rules (using fwmark)
```bash
# View all rules
sudo ipvsadm -Ln

# View statistics
sudo ipvsadm -Ln --stats

# View connection tracking
sudo ipvsadm -Ln --rate
```

**Expected output with fwmark:**
```
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
FWM  1 rr
  -> 10.10.20.11:0                Masq    1      0          0
  -> 10.10.20.12:0                Masq    1      0          0
  -> 10.10.20.13:0                Masq    1      0          0
```

**Key difference:** Only **ONE** entry (FWM 1) instead of 10,001 entries!

---

### Check Keepalived logs
```bash
# View realtime logs
sudo journalctl -u keepalived -f

# View recent logs
sudo journalctl -u keepalived -n 50
```

**Sample log when pod dies:**
```
Keepalived_healthcheckers: TCP connection to [10.10.20.13]:7880 failed !!!
Keepalived_healthcheckers: Removing service [10.10.20.13]:0 from VS FWM:1
```

**Sample log when pod comes alive:**
```
Keepalived_healthcheckers: TCP connection to [10.10.20.13]:7880 success.
Keepalived_healthcheckers: Adding service [10.10.20.13]:0 to VS FWM:1
```

---

### Test connections

**Test iptables marking:**
```bash
# Send test UDP packet
echo "TEST" | nc -u 13.212.50.46 50034

# Check if packet was marked
sudo conntrack -L | grep 50034
```

**Test TCP signaling:**
```bash
vào trình duyệt 
https://livekit.thang2k6adu.xyz/
```

**Test UDP forwarding:**
```bash
# From another node, send UDP packet
echo "TEST_UDP_PACKET" | nc -u 13.212.50.46 57186 -p 50001 -vv

# On backend node, capture packets
sudo tcpdump -i any port 57186 -n -vv
```

---

## Part 6: Health Check Principles

### Why use TCP port 7880 instead of UDP?

**UDP cannot be checked directly:**
- UDP is a **connectionless protocol**, no handshake
- Sending UDP packet doesn't confirm if server received it
- No response confirmation

**Solution:**
- LiveKit exposes **TCP port 7880** (signaling)
- If TCP 7880 **ALIVE** → Pod works normally
- If TCP 7880 **DEAD** → Pod dead → Keepalived removes from IPVS

---

### Health Check Configuration
```nginx
TCP_CHECK {
    connect_port 7880           # LiveKit signaling port
    connect_timeout 3           # Timeout 3 seconds
    retry 3                     # Retry 3 times
    delay_before_retry 3        # Wait 3 seconds between retries
}
```

**Workflow:**
```
Every 5 seconds (delay_loop 5):
  Keepalived → TCP connect 10.10.20.11:7880
    ↓
  SUCCESS → Pod is alive
    → Keep in IPVS table
    → Continue receiving UDP traffic via fwmark
    ↓
  FAIL (retry 3 times)
    → Pod is dead
    → REMOVE from IPVS table (FWM 1)
    → NO MORE UDP traffic to this pod
```

---

## Part 7: Management & Maintenance

### Add/Remove backend node

**Step 1: Edit backend file**
```bash
sudo nano /etc/nginx/backends/cluster-dev-livekit.conf
```

Add or remove line:
```nginx
server 10.10.20.11:7880;
server 10.10.20.12:7880;
server 10.10.20.13:7880;
server 10.10.20.14:7880;  # ← Add new node
```

**Step 2: Regenerate Keepalived config**
```bash
sudo /usr/local/bin/gen-keepalived-fwmark.sh
```

**Step 3: Reload Keepalived**
```bash
sudo systemctl reload keepalived
```

**Step 4: Check**
```bash
sudo ipvsadm -Ln | grep 10.10.20.14
```

---

### Change port range

**If you need to adjust the port range (e.g., 40000-60000):**

**Step 1: Update fwmark script**
```bash
sudo nano /usr/local/bin/setup-fwmark.sh
```

Change:
```bash
START_PORT=40000  # ← Change here
END_PORT=60000
```

**Step 2: Re-run fwmark setup**
```bash
sudo /usr/local/bin/setup-fwmark.sh
sudo netfilter-persistent save
```

**Step 3: Restart Keepalived**
```bash
sudo systemctl restart keepalived
```

---

### Remove all IPVS rules (Emergency)

**Method 1: Stop Keepalived (Recommended)**
```bash
sudo systemctl stop keepalived
```

Keepalived will automatically remove all IPVS rules when stopped.

**Method 2: Manual removal**
```bash
# Remove fwmark rule
sudo ipvsadm -D -f 1
```

---

### Backup & Restore

**Backup IPVS rules:**
```bash
sudo ipvsadm-save > ~/ipvs-backup-$(date +%Y%m%d).conf
```

**Restore IPVS rules:**
```bash
sudo ipvsadm-restore < ~/ipvs-backup-20241208.conf
```

**Backup Keepalived config:**
```bash
sudo cp /etc/keepalived/keepalived.conf ~/keepalived-backup-$(date +%Y%m%d).conf
```

**Backup iptables rules:**
```bash
sudo iptables-save > ~/iptables-backup-$(date +%Y%m%d).rules
```

---

## Part 8: Production Optimization

### Increase connection tracking limit
```bash
# View current limit
sudo sysctl net.netfilter.nf_conntrack_max

# Increase (example: 524288 for high traffic)
sudo sysctl -w net.netfilter.nf_conntrack_max=524288
echo "net.netfilter.nf_conntrack_max=524288" | sudo tee -a /etc/sysctl.conf
```

---

### Increase timeout for UDP sessions
```bash
# Default: 30 seconds → Increase to 300 seconds for long calls
sudo sysctl -w net.netfilter.nf_conntrack_udp_timeout=300
echo "net.netfilter.nf_conntrack_udp_timeout=300" | sudo tee -a /etc/sysctl.conf

# Apply changes
sudo sysctl -p
```

---

### Auto-reload when backend changes

**Create systemd path unit:**
```bash
sudo nano /etc/systemd/system/keepalived-reload.path
```
```ini
[Unit]
Description=Watch backend file for changes

[Path]
PathModified=/etc/nginx/backends/cluster-dev-livekit.conf

[Install]
WantedBy=multi-user.target
```

**Create systemd service:**
```bash
sudo nano /etc/systemd/system/keepalived-reload.service
```
```ini
[Unit]
Description=Reload Keepalived on backend change

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gen-keepalived-fwmark.sh
ExecStartPost=/bin/systemctl reload keepalived
```

**Enable:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable keepalived-reload.path
sudo systemctl start keepalived-reload.path
```

**Test:**
```bash
# Edit backend file
sudo nano /etc/nginx/backends/cluster-dev-livekit.conf

# Keepalived will auto-reload after a few seconds
sudo journalctl -u keepalived-reload.service -f
```

---

## Part 9: Debugging & Troubleshooting

### Pod not receiving traffic

**Check:**
```bash
# 1. Is fwmark rule active?
sudo iptables -t mangle -L PREROUTING -n -v | grep 50000

# 2. Is pod in IPVS table?
sudo ipvsadm -Ln | grep <POD_IP>

# 3. Is pod's TCP 7880 alive?
telnet <POD_IP> 7880

# 4. Any errors in Keepalived logs?
sudo journalctl -u keepalived -n 100 | grep <POD_IP>
```

---

### fwmark not working

**Check:**
```bash
# 1. Is iptables rule present?
sudo iptables -t mangle -L PREROUTING -n -v

# 2. Test packet marking
sudo conntrack -L | grep -E "50[0-9]{3}"

# 3. Check IPVS has fwmark rule
sudo ipvsadm -Ln | grep FWM
```

**If fwmark rule missing, recreate:**
```bash
sudo /usr/local/bin/setup-fwmark.sh
sudo systemctl restart keepalived
```

---

### Keepalived not creating IPVS rules

**Check:**
```bash
# 1. Is Keepalived running?
sudo systemctl status keepalived

# 2. Any syntax errors in config?
sudo keepalived -t -f /etc/keepalived/keepalived.conf

# 3. Are kernel modules loaded?
lsmod | grep ip_vs

# 4. Check full logs
sudo journalctl -u keepalived -n 200
```

---

### UDP traffic not being forwarded

**Check:**
```bash
# 1. Is IP forwarding enabled?
sudo sysctl net.ipv4.ip_forward

# 2. Is connection tracking sufficient?
sudo sysctl net.netfilter.nf_conntrack_max
sudo conntrack -L | wc -l

# 3. Are packets being marked?
sudo iptables -t mangle -L PREROUTING -n -v -x

# 4. Test with tcpdump on VPS
sudo tcpdump -i any port 50034 -n -vv

# 5. Test with tcpdump on backend
sudo tcpdump -i any port 50034 -n -vv
```

---

## Part 11: Complete Sample Configuration

### Sample Keepalived Config (After generation)

**Location:** `/etc/keepalived/keepalived.conf`

```nginx
global_defs {
   router_id LIVEKIT_LVS
}

# ──────────────────────────────────────────────────────
# Virtual Server using fwmark (covers port 50000-60000)
# ──────────────────────────────────────────────────────
virtual_server fwmark 1 {
    delay_loop 5        # Health check every 5 seconds
    lb_algo rr          # Round Robin
    lb_kind NAT         # NAT mode
    protocol UDP        # UDP traffic

    real_server 10.10.20.11 0 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3                     # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
    real_server 10.10.20.12 0 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3                     # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
    real_server 10.10.20.13 0 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3                     # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
}
```

---

### Sample iptables mangle rule

**Check with:**
```bash
sudo iptables -t mangle -L PREROUTING -n -v
```

**Expected output:**
```
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
 1234  567K MARK       udp  --  *      *       0.0.0.0/0            13.212.50.46        udp dpts:50000:60000 MARK set 0x1
```

---

### Sample IPVS output

**Check with:**
```bash
sudo ipvsadm -Ln
```

**Expected output:**
```
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
FWM  1 rr
  -> 10.10.20.11:0                Masq    1      0          5
  -> 10.10.20.12:0                Masq    1      0          3
  -> 10.10.20.13:0                Masq    1      0          2
```


# 1. Tạo một routing table mới (ví dụ tên là vpn_route)
echo "200 vpn_route" | sudo tee -a /etc/iproute2/rt_tables

# 2. Trỏ default gateway của table này về IP của con VPS (trong mạng WireGuard)
# Giả sử IP VPN của VPS là 10.10.20.1, interface là wg0
sudo ip route add default via 10.10.20.1 dev wg0 table 200

# 3. Đánh dấu các gói tin UDP chui ra từ cổng 50000-60000 của LiveKit
sudo iptables -t mangle -A OUTPUT -p udp --sport 50000:60000 -j MARK --set-mark 2

# 4. Ép các gói bị đánh dấu phải đi theo cái table 200 vừa tạo
sudo ip rule add fwmark 2 table 200


vps
sudo iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE