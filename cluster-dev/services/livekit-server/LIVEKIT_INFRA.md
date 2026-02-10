# IPVS + Keepalived Configuration Guide for LiveKit

## Architecture Explanation

### Problem to Solve

LiveKit requires 2 types of connections:

1. **TCP (Signaling) - Port 7880/7881:**
   - Client connects to establish session
   - Nginx reverse proxy can handle this
   
2. **UDP (Media/RTP) - Port 50000-60000:**
   - Actual audio, video transmission
   - **Nginx CANNOT reverse proxy UDP**
   - Need alternative solution → **IPVS**

---

### Role of Each Component

| Component | Role | Protocol |
|-----------|------|----------|
| **Nginx** | Reverse proxy signaling | TCP 7880/7881 |
| **IPVS** | Load balance media traffic (MAIN TOOL) | UDP 50000-60000 |
| **Keepalived** | Health check + Manage IPVS (AUXILIARY TOOL) | TCP 7880 (check) |

**What Keepalived does:**
- Automatically create IPVS rules (no manual script needed)
- Health check TCP port 7880 every 5 seconds
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
VPS (IPVS - Load Balancer)
  |    ↑
  |    └─ Keepalived (Health Check TCP 7880)
  |
  ├─> LiveKit Pod 1 (10.10.20.11:50000-60000)
  ├─> LiveKit Pod 2 (10.10.20.12:50000-60000)
  └─> LiveKit Pod 3 (10.10.20.13:50000-60000) (chết, bị loại)
```

---

### SDP Response Example

Client sends signal TCP → port 7880

LiveKit returns SDP:
```
v=0
o=- 46117326 2 IN IP4 127.0.0.1
s=-
t=0 0
a=ice-ufrag:abcd
a=ice-pwd:1234567890abcdef
a=fingerprint:sha-256 12:34:56:78:...
m=audio 50034 UDP/TLS/RTP/SAVPF 111
a=candidate:1 1 UDP 2130706431 203.0.113.10 50034 typ host
a=candidate:2 1 UDP 1694498815 203.0.113.10 52311 typ srflx
m=video 50036 UDP/TLS/RTP/SAVPF 96
a=candidate:3 1 UDP 2130706431 203.0.113.10 50036 typ host
```

**Meaning:** Client needs to connect UDP to port **50034** (audio) and **50036** (video)

IPVS will forward these ports to backend pods.

---

## Part 1: Installation & Basic Configuration

### Step 1: Install packages
```bash
sudo apt update
sudo apt install -y ipvsadm keepalived iproute2
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
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## Part 2: Backend Nodes Configuration

### Step 4: Create backend list file

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

## Part 3: Keepalived Configuration (Automatic IPVS Management)

### Step 5: Create script to generate Keepalived config file (remember to adjust for your environment)
```bash
sudo nano /usr/local/bin/gen-keepalived.sh
```

**Script content:**
```bash
#!/bin/bash

PUBLIC_IP="13.212.50.46"  
START_PORT=50000                 
END_PORT=60000                    
BACKEND_FILE="/etc/nginx/backends/cluster-dev-livekit.conf"
OUTPUT="/etc/keepalived/keepalived.conf"

BACKENDS=$(awk '{print $2}' $BACKEND_FILE | sed 's/;//g' | cut -d: -f1)

if [ -z "$BACKENDS" ]; then
    echo "No backends found in $BACKEND_FILE"
    exit 1
fi

echo "Found Backends:"
echo "$BACKENDS"
echo ""

cat > $OUTPUT <<EOF
global_defs {
   router_id LIVEKIT_LVS
}
EOF

echo "Creating IPVS rules for port range $START_PORT-$END_PORT..."

for p in $(seq $START_PORT $END_PORT); do
cat >> $OUTPUT <<EOF

# ──────────────────────────────────────────────────────
# Virtual Server: $PUBLIC_IP:$p
# ──────────────────────────────────────────────────────
virtual_server $PUBLIC_IP $p {
    delay_loop 5        # Health check every 5 seconds
    lb_algo sh          # Source Hashing (maintain session)
    lb_kind NAT         # NAT mode
    protocol UDP        # UDP traffic

EOF

    # Add real servers with health check
    for ip in $BACKENDS; do
cat >> $OUTPUT <<EOF
    real_server $ip $p {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry  3                    # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
EOF
    done

    echo "}" >> $OUTPUT
done

echo ""
echo "Keepalived config has been created at: $OUTPUT"
echo "Total virtual servers: $((END_PORT - START_PORT + 1))"
echo "Backend servers count: $(echo "$BACKENDS" | wc -l)"
```

**Grant execution permission:**
```bash
sudo chmod +x /usr/local/bin/gen-keepalived.sh
```

---

### Step 6: Run script and start Keepalived
```bash
# 1. Create Keepalived config file
sudo /usr/local/bin/gen-keepalived.sh

# 2. Check syntax
sudo keepalived -t -f /etc/keepalived/keepalived.conf

# 3. Enable service
sudo systemctl enable keepalived

# 4. Start Keepalived (will automatically create IPVS rules)
sudo systemctl start keepalived

# 5. Check status
sudo systemctl status keepalived
```

**Important note:**
- Keepalived will **AUTOMATICALLY** create IPVS rules when started
- Keepalived will **AUTOMATICALLY** health check TCP 7880
- Keepalived will **AUTOMATICALLY** remove/add backend when dead/alive
- **NO NEED** to run `ipvs-forward` script manually anymore

---

## Part 4: Checking & Troubleshooting

### Check IPVS rules (created by Keepalived)
```bash
# View all rules
sudo ipvsadm -Ln

# View statistics
sudo ipvsadm -Ln --stats

# View connection tracking
sudo ipvsadm -Ln --rate
```

**Sample output:**
```
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
UDP  13.212.50.46:50000 sh
  -> 10.10.20.11:50000            Masq    1      0          0
  -> 10.10.20.12:50000            Masq    1      0          0
  -> 10.10.20.13:50000            Masq    1      0          0
...
```

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
Keepalived_healthcheckers: Removing service [10.10.20.13]:50000 from VS [13.212.50.46]:50000
```

**Sample log when pod comes alive:**
```
Keepalived_healthcheckers: TCP connection to [10.10.20.13]:7880 success.
Keepalived_healthcheckers: Adding service [10.10.20.13]:50000 to VS [13.212.50.46]:50000
```

---

### Test connections

**Test TCP signaling:**
```bash
telnet 13.212.50.46 7880
```

**Test UDP port:**
```bash
# Install netcat if not available
sudo apt install netcat

# Test UDP
nc -u -v 13.212.50.46 50034
```

---

## Part 5: Health Check Principles

### Why use TCP port 7880 instead of UDP for health check?

**According to Keepalived documentation:**

> "UDP services cannot be checked directly; only TCP or external scripts can be used for health checking."

**Explanation:**
- UDP is a **connectionless protocol**, no handshake
- Sending UDP packet doesn't know if server received it
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
    retry 3              # Retry 3 times
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
    → Receive UDP traffic normally
    ↓
  FAIL (retry 3 times)
    → Pod is dead
    → REMOVE from IPVS table
    → NO MORE UDP traffic
```

---

## Part 6: Management & Maintenance

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
sudo /usr/local/bin/gen-keepalived.sh
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

### Remove all IPVS rules (Emergency)

**Method 1: Stop Keepalived (Recommended)**
```bash
sudo systemctl stop keepalived
```

Keepalived will automatically remove all IPVS rules when stopped.

**Method 2: Manual removal**
```bash
# WARNING: Removes entire IPVS table
sudo ipvsadm -C
```

**Method 3: Safe removal by port range**
```bash
for p in $(seq 50000 60000); do
  sudo ipvsadm -D -u 13.212.50.46:$p 2>/dev/null
done
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

---

## Part 7: Production Optimization

### Increase connection tracking limit
```bash
# View current limit
sudo sysctl net.netfilter.nf_conntrack_max

# Increase (example: 262144)
sudo sysctl -w net.netfilter.nf_conntrack_max=262144
echo "net.netfilter.nf_conntrack_max=262144" | sudo tee -a /etc/sysctl.conf
```

---

### Increase timeout for UDP sessions
```bash
# Default: 30 seconds → Increase to 180 seconds
sudo sysctl -w net.netfilter.nf_conntrack_udp_timeout=180
echo "net.netfilter.nf_conntrack_udp_timeout=180" | sudo tee -a /etc/sysctl.conf
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
ExecStart=/usr/local/bin/gen-keepalived.sh
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

## Part 8: Debugging & Troubleshooting

### Pod not receiving traffic

**Check:**
```bash
# 1. Is pod in IPVS table?
sudo ipvsadm -Ln | grep <POD_IP>

# 2. Is pod's TCP 7880 alive?
telnet <POD_IP> 7880

# 3. Any errors in Keepalived logs?
sudo journalctl -u keepalived -n 100 | grep <POD_IP>
```

---

### Keepalived not creating IPVS rules

**Check:**
```bash
# 1. Is Keepalived running?
sudo systemctl status keepalived

# 2. Any syntax errors in config file?
sudo keepalived -t -f /etc/keepalived/keepalived.conf

# 3. Are kernel modules loaded?
lsmod | grep ip_vs
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

# 3. Is firewall blocking?
sudo iptables -L -n -v
```

---

global_defs {
   router_id LIVEKIT_LVS
}

# ──────────────────────────────────────────────────────
# Virtual Server: 13.212.50.46:50000
# ──────────────────────────────────────────────────────
virtual_server 13.212.50.46 50000 {
    delay_loop 5        # Health check every 5 seconds
    lb_algo sh          # Source Hashing (maintain session)
    lb_kind NAT         # NAT mode
    protocol UDP        # UDP traffic

    real_server 10.10.20.11 50000 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3              # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
    real_server 10.10.20.12 50000 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3              # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
    real_server 10.10.20.13 50000 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3              # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
}

# ──────────────────────────────────────────────────────
# Virtual Server: 13.212.50.46:50001
# ──────────────────────────────────────────────────────
virtual_server 13.212.50.46 50001 {
    delay_loop 5        # Health check every 5 seconds
    lb_algo sh          # Source Hashing (maintain session)
    lb_kind NAT         # NAT mode
    protocol UDP        # UDP traffic

    real_server 10.10.20.11 50001 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3              # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
    real_server 10.10.20.12 50001 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3              # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
    real_server 10.10.20.13 50001 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3              # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
}

# ... (Continue for port 50002, 50003... to 60000)
# ... TOTAL: 10,001 virtual servers

# ──────────────────────────────────────────────────────
# Virtual Server: 13.212.50.46:60000
# ──────────────────────────────────────────────────────
virtual_server 13.212.50.46 60000 {
    delay_loop 5        # Health check every 5 seconds
    lb_algo sh          # Source Hashing (maintain session)
    lb_kind NAT         # NAT mode
    protocol UDP        # UDP traffic

    real_server 10.10.20.11 60000 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3              # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
    real_server 10.10.20.12 60000 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3              # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
    real_server 10.10.20.13 60000 {
        weight 1
        TCP_CHECK {
            connect_port 7880           # Health check TCP 7880
            connect_timeout 3           # Timeout 3 seconds
            retry 3              # Retry 3 times
            delay_before_retry 3        # Wait 3 seconds between retries
        }
    }
}
```