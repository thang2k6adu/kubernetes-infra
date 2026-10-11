# Runbook: đưa LiveKit lên prod cho syncflow-room

Mục tiêu: `syncflow-room` cấp được token LiveKit, client (browser/Flutter) vào phòng qua `wss://livekit.kruzetech.dev` và media WebRTC chạy được.

## 0. Sơ đồ và các giá trị cố định

```
Client ──wss 443──► VPS nginx (34.126.172.66) ──► 10.10.10.12:7880  (signalling, qua WireGuard)
Client ──UDP 50000-60000──► VPS iptables DNAT ──► 10.10.10.12        (media, qua WireGuard)
syncflow-room ──http──► prod-livekit-server.livekit-server.svc:7880   (admin API, trong cluster)
livekit ──webhook──► prod-syncflow-room.syncflow-room.svc:3030/api/livekit/webhook
```

| Giá trị | Giá trị cụ thể | Lý do |
|---|---|---|
| IP public VPS (GCP) | `34.126.172.66`, NIC `ens4` | client chỉ thấy IP này |
| Worker chạy LiveKit | `k3s-worker-51` = VPN `10.10.10.12` | `nodeSelector` ghim pod vào đúng node, DNAT/nginx trỏ đúng node |
| `rtc.node_ip` | `34.126.172.66` | ICE candidate phải quảng bá IP của VPS, không phải IP worker |
| `rtc.use_external_ip` | `false` | nó hỏi STUN và nhận IP egress của worker, sai IP |
| Pod | `hostNetwork: true` | 7880, 7881/tcp và UDP 50000-60000 mở thẳng trên node, không cần NodePort |
| TURN | tắt | chưa cần cho devtest; mạng 4G/doanh nghiệp chặn UDP sẽ không vào được (xem mục 7) |

Chạy lệnh ở đâu: `[master]` = máy chạy ansible/kubectl, `[VPS]` = GCP VPS, `[worker]` = k3s-worker-51, `[local]` = máy bạn.

---

## 1. DNS

Lý do: certbot cần domain trỏ về VPS, client cần resolve được domain.

Trỏ bản ghi A `livekit.kruzetech.dev` về `34.126.172.66` (DNS "DNS only", không bật proxy kiểu CDN nếu nhà cung cấp có).

Kiểm tra `[local]`:
```bash
dig +short livekit.kruzetech.dev      # phải ra đúng 34.126.172.66
```

## 2. Firewall

### 2.1. Firewall cloud (GCP VPC) cho VPS

Lý do: GCP chặn mặc định mọi thứ không khai; nếu thiếu thì DNAT trên VPS không bao giờ nhận được gói UDP.

| Port | Proto | Mục đích |
|---|---|---|
| 80, 443 | TCP | certbot + wss |
| 50000-60000 | UDP | media WebRTC (51820 vẫn là WireGuard, đã mở từ trước) |
| 7881 | TCP | tuỳ chọn, fallback RTC qua TCP (cần thêm DNAT ở bước 3.3) |

Kiểm tra `[local]` (sau bước 3): `nc -zvu 34.126.172.66 50000` không báo lỗi ngay không chứng minh gì (UDP), kiểm tra thật ở mục 6.

### 2.2. Firewall worker (ufw bằng ansible) theo `OPEN_PORT.md`

Lý do: VPS gửi gói qua WireGuard tới `10.10.10.12`; ufw trên worker phải cho phép các port này.

`[master]`:
```bash
nano ~/k3s-inventory/open_livekit_ports.yml     # nội dung đúng như cluster-prod/services/livekit-server/OPEN_PORT.md
ansible-playbook -i ~/k3s-inventory/hosts.ini ~/k3s-inventory/open_livekit_ports.yml
```
Kiểm tra `[worker]`:
```bash
sudo ufw status | grep -E "7880/tcp|7881/tcp|50000:60000/udp"   # phải thấy đủ 3 dòng
```

## 3. iptables DNAT trên VPS

Lý do: media WebRTC là UDP thẳng tới IP public của VPS, nginx không proxy được UDP nên phải DNAT về worker.

### 3.1. Chạy script (đúng như `LIVEKIT_INFRA_NEW.md`)

KHÔNG chạy `iptables -t nat -F`: sẽ xoá rule `8022` (SSH vào master). Script dùng `-C || -A` nên chạy lại nhiều lần không trùng.

`[VPS]`: copy phần lệnh trong `cluster-prod/services/livekit-server/LIVEKIT_INFRA_NEW.md` (từ dòng `echo "net.ipv4.ip_forward=1"` đến hết) vào file rồi chạy:
```bash
nano ~/livekit-nat.sh && chmod +x ~/livekit-nat.sh && ~/livekit-nat.sh
```
Script chia 50000-51819 và 51821-60000, bỏ 51820 vì là WireGuard.

### 3.2. Kiểm tra

```bash
ip -br a show ens4                                  # xác nhận đúng tên NIC public, nếu khác ens4 thì sửa script
sudo iptables -t nat -S | grep -E "8022|50000|51821"   # phải còn rule 8022 cũ + 2 DNAT + 2 MASQUERADE
sudo iptables -S FORWARD | head -1                  # nên là -P FORWARD ACCEPT; nếu DROP phải thêm rule FORWARD cho 10.10.10.12
sudo iptables -t nat -S | grep -c 51820             # phải ra 0 (không forward WireGuard)
sudo netfilter-persistent save                      # script đã gọi, gọi lại cũng không hại
ls -l /etc/iptables/rules.v4
```
Lý do kiểm FORWARD: script không thêm rule FORWARD; nếu có firewall chặn forward thì DNAT vẫn mất gói.

### 3.3. Tuỳ chọn: TCP 7881 (fallback)

Lý do: LiveKit quảng bá thêm candidate `34.126.172.66:7881/tcp`; không DNAT thì candidate này chết (vô hại nhưng mất đường lùi cho mạng chặn UDP). Muốn dùng thì mở thêm port 7881/tcp ở GCP rồi:
```bash
sudo iptables -t nat -C PREROUTING -i ens4 -p tcp --dport 7881 -j DNAT --to-destination 10.10.10.12 2>/dev/null \
  || sudo iptables -t nat -A PREROUTING -i ens4 -p tcp --dport 7881 -j DNAT --to-destination 10.10.10.12
sudo iptables -t nat -C POSTROUTING -p tcp -d 10.10.10.12 --dport 7881 -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -p tcp -d 10.10.10.12 --dport 7881 -j MASQUERADE
sudo netfilter-persistent save
```

## 4. Nginx trên VPS

Lý do: `livekit.kruzetech.dev` không đi qua ingress-nginx (`30080`) mà phải vào thẳng `10.10.10.12:7880` (pod hostNetwork), nên cần backend/upstream riêng.

### 4.1. Backend và upstream (theo `MODIFY_RESERVE_PROXY.md`)

`[VPS]`:
```bash
echo "server 10.10.10.12:7880;" | sudo tee /etc/nginx/backends/cluster-prod-livekit.conf

# thêm upstream nếu chưa có (chạy lại không bị ghi trùng)
grep -q "cluster-prod-livekit" /etc/nginx/conf.d/ingress_upstream.conf || sudo tee -a /etc/nginx/conf.d/ingress_upstream.conf <<'EOF'

upstream cluster-prod-livekit {
    least_conn;
    include /etc/nginx/backends/cluster-prod-livekit.conf;
}
EOF
```
Chỉ khai 1 node vì chỉ `10.10.10.12` chạy LiveKit; khai node khác thì request đầu bị chậm do nginx thử node chết.

Kiểm tra backend sống từ VPS (trước khi LiveKit được deploy sẽ không ra OK, quay lại kiểm sau mục 5):
```bash
curl -s http://10.10.10.12:7880 ; echo        # phải ra: OK
```

### 4.2. Tạo vhost + cấp cert

```bash
sudo add-domain livekit.kruzetech.dev cluster-prod
```
Script tạo vhost, chạy certbot rồi ghi lại vhost cuối cùng với `proxy_pass http://cluster-prod;`. Cần DNS (mục 1) và port 80 mở thì certbot mới cấp được cert.

### 4.3. Sửa vhost cho LiveKit

```bash
F=/etc/nginx/sites-available/livekit.kruzetech.dev
sudo cp $F $F.bak
# 1) trỏ sang upstream LiveKit (LiveKit không có TLS nên http://)
sudo sed -i 's#proxy_pass http://cluster-prod;#proxy_pass http://cluster-prod-livekit;#g' $F
# 2) websocket signalling sống lâu: nâng timeout trong location @websocket từ 600s lên 3600s
sudo sed -i '/location @websocket/,/^    }/ s/proxy_read_timeout 600s;/proxy_read_timeout 3600s;/; /location @websocket/,/^    }/ s/proxy_send_timeout 600s;/proxy_send_timeout 3600s;/' $F
grep -nE "proxy_pass|proxy_(read|send)_timeout|Upgrade|Connection" $F
```
Phải thấy: cả 2 `proxy_pass` là `cluster-prod-livekit`, `@websocket` có 3600s, và header `Upgrade`/`Connection $connection_upgrade` (script đã sinh sẵn, đây là phần WebSocket upgrade; không cần sửa thêm).

- Không cần chỉnh `client_max_body_size`: LiveKit không nhận upload lớn qua nginx (mặc định `50m` của script là thừa nhưng vô hại).
- Lý do 3600s: LiveKit tự ping qua websocket nên 600s cũng thường đủ, nhưng nâng lên để không bị cắt khi mạng chập chờn làm mất ping.

```bash
sudo nginx -t && sudo systemctl reload nginx
```

### 4.4. Kiểm tra nginx

```bash
curl -sI http://livekit.kruzetech.dev | head -3        # 301 -> https
curl -s https://livekit.kruzetech.dev ; echo            # OK (sau khi LiveKit chạy, mục 5)
sudo certbot certificates | grep -A2 livekit.kruzetech.dev
```
Nếu `502`: LiveKit chưa chạy hoặc `10.10.10.12:7880` không tới được từ VPS (`curl` ở 4.1).

## 5. ArgoCD: thứ tự sync

Lý do: ApplicationSet tự sync mọi tenant cùng lúc (retry 15 lần, backoff tới 5 phút). Thứ tự dưới đây là thứ tự để kiểm tra và biết sai ở đâu; room chỉ khoẻ khi DB + Redis + LiveKit sẵn sàng.

```bash
kubectl -n argocd get applications.argoproj.io | grep -E "syncflow-(db|redis|room|gateway)|livekit-server"
```

| # | App | Lệnh kiểm tra | Kỳ vọng |
|---|---|---|---|
| 1 | `syncflow-db` | `kubectl -n syncflow-db get job syncflow-room-db-init` | `COMPLETIONS 1/1` (job tạo DB `kruzetech_room`). Lỗi: `kubectl -n syncflow-db logs job/syncflow-room-db-init` |
| 2 | `syncflow-redis` | `kubectl -n syncflow-redis get pods` | `prod-syncflow-redis-master-0` Running 1/1 |
| 3 | `livekit-server` | `kubectl -n livekit-server get pods -o wide` | Running 1/1 và cột NODE = `k3s-worker-51` |
| 4 | `syncflow-room` | `kubectl -n syncflow-room get pods` | Running 1/1 (xem lưu ý image bên dưới) |
| 5 | `syncflow-gateway` | `kubectl -n syncflow-gateway get pods` | Running 1/1 |

Kiểm tra sâu cho bước 3 (LiveKit):
```bash
kubectl -n livekit-server logs deploy/prod-livekit-server --tail=30
kubectl -n livekit-server get svc prod-livekit-server        # port 7880/TCP và 7881/TCP
kubectl -n livekit-server get endpoints prod-livekit-server  # endpoint = IP LAN của k3s-worker-51
# từ trong cluster (cùng đường mà room dùng):
kubectl -n syncflow-room run curl-lk --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s http://prod-livekit-server.livekit-server.svc.cluster.local:7880 ; echo   # phải ra OK
```
Từ `[worker]` hoặc `[VPS]`: `curl -s http://10.10.10.12:7880` phải ra `OK` (đây là lệnh `checkl <nodeip>:7880` trong `OPEN_PORT.md`).

Lưu ý image của room: tag trong `values.yaml` là placeholder `git-000...0`. Pod `syncflow-room` sẽ `ImagePullBackOff` cho đến khi CI repo `Vocab_Flow_Backend` đẩy image `registry.kruzetech.dev/kruzetech-room:git-<sha>` lên Nexus và argocd-image-updater (chu kỳ ~2 phút) commit file `cluster-prod/tenants/syncflow-room/.argocd-source-syncflow-room.yaml` vào `main`. Kiểm tra:
```bash
kubectl -n argocd logs deploy/argocd-image-updater --tail=50 | grep -i room
git pull && cat cluster-prod/tenants/syncflow-room/.argocd-source-syncflow-room.yaml
```
Nếu thay đổi `values.yaml` của tenant, nhớ bản `services/<tên>/values.yaml` giống hệt.

## 6. Kiểm tra end-to-end

### 6.1. HTTP/WebSocket qua nginx

```bash
curl -s https://livekit.kruzetech.dev ; echo                       # OK
curl -s https://syncflow-gateway.kruzetech.dev/api/health ; echo   # health qua gateway -> room
```
Trong repo gateway, `/api/rooms`, `/api/matchmaking`, `/api/livekit`, `/socket.io` đều trỏ vào room.

### 6.2. Room gọi được LiveKit và nhận được webhook

```bash
kubectl -n syncflow-room logs deploy/prod-syncflow-room --tail=200 | grep -E "LiveKit admin call ok|LiveKit webhook event="
```
- `LiveKit admin call ok`: room gọi `LIVEKIT_API_URL` thành công (Service port 7880, key/secret đúng).
- `LiveKit webhook event=...`: LiveKit gọi ngược được room (JWT webhook ký bằng `devkey`). Sinh ra khi có người vào/rời phòng.
- Lỗi thường gặp: `connection refused` → Service sai port; `401`/`invalid token` → key/secret ở `livekit-server-secret` lệch với `syncflow-room-secret`.

### 6.3. Media thật (UDP)

Lý do: HTTP OK không chứng minh UDP chạy. Tạo token thử `[local]` (cần `lk`, secret lấy từ nơi lưu secret, không ghi vào repo):
```bash
lk token create --api-key devkey --api-secret '<LIVEKIT_API_SECRET>' --join --room test --identity u1 --valid-for 1h
```
Mở https://livekit.io/connection-test, nhập URL `wss://livekit.kruzetech.dev` và token. Cả bước "UDP" lẫn "TCP" nên xanh (TCP chỉ xanh nếu đã làm 3.3).

Song song, thấy gói UDP đi qua từng chặng:
```bash
# [VPS]
sudo tcpdump -ni ens4 udp portrange 50000-60000 -c 10     # gói từ client tới
sudo tcpdump -ni wg0  udp portrange 50000-60000 -c 10     # gói đã DNAT sang 10.10.10.12
# [worker]
sudo tcpdump -ni any udp portrange 50000-60000 -c 10
```
Thấy ở `ens4` mà không thấy ở `wg0` → sai DNAT/FORWARD. Thấy ở `wg0` mà không có ở worker → ufw/WireGuard. Không thấy ở `ens4` → firewall GCP (2.1) hoặc client không dùng IP đúng (kiểm tra candidate trong connection-test phải có `34.126.172.66`).

## 7. Giới hạn đã biết

- TURN đang tắt: client sau NAT/mạng chặn UDP không có UDP relay. Muốn bật phải mở `3478/udp` + `5349/tcp` trên GCP, DNAT sang worker và bật `livekit.turn` trong values (chưa làm).
- Chỉ 1 replica, Redis tắt: mất pod là rớt hết phòng. `terminationGracePeriodSeconds` để 600s cho devtest (chart cũ để 5 giờ làm redeploy bị treo).
- MASQUERADE trên VPS làm LiveKit thấy mọi client có cùng IP nguồn (IP VPN của VPS); không ảnh hưởng media nhưng log LiveKit không có IP client thật.
- Tag image `livekit-server` ghim `v1.9.0` (trước là `latest`).

## 8. Rollback

| Việc | Cách gỡ |
|---|---|
| Nginx vhost | `sudo rm -f /etc/nginx/sites-enabled/livekit.kruzetech.dev /etc/nginx/sites-available/livekit.kruzetech.dev && sudo certbot delete --cert-name livekit.kruzetech.dev && sudo nginx -t && sudo systemctl reload nginx`; xoá block `upstream cluster-prod-livekit` và file `/etc/nginx/backends/cluster-prod-livekit.conf` |
| Sửa nhầm vhost | `sudo cp /etc/nginx/sites-available/livekit.kruzetech.dev.bak /etc/nginx/sites-available/livekit.kruzetech.dev && sudo nginx -t && sudo systemctl reload nginx` |
| DNAT UDP | thay `-A` bằng `-D` trên đúng 4 rule của script, rồi `sudo netfilter-persistent save`. KHÔNG dùng `-F` (mất rule 8022). Xoá file `/etc/sysctl.d/99-livekit.conf` nếu muốn bỏ tuning conntrack |
| ufw worker | `sudo ufw delete allow 7880/tcp; sudo ufw delete allow 7881/tcp; sudo ufw delete allow 50000:60000/udp` |
| Cấu hình LiveKit trong repo | `git revert` commit đổi `values.yaml` (2 bản `services/` và `tenants/` đổi cùng nhau), ArgoCD tự sync lại |
| Tắt LiveKit hẳn | đặt `replicaCount: 0` trong cả 2 `values.yaml` (room vẫn chạy nhưng tạo phòng/token sẽ lỗi) |
| DNS | xoá bản ghi A `livekit.kruzetech.dev` |

## 9. Bảo mật: xoay secret LiveKit

API secret của key `devkey` từng nằm dạng chữ thường trong comment của `values.yaml` và `README.md` (đã thay bằng placeholder) và còn trong lịch sử git. Phải coi là đã lộ, xoay secret:

1. Sinh secret mới (>= 32 ký tự ngẫu nhiên).
2. Cập nhật `keys.yaml` trong `cluster-prod/services/livekit-server/.env` và `LIVEKIT_API_SECRET` trong `cluster-prod/services/syncflow-room/.env` (cùng một giá trị mới; các `.env` của service khác cùng dùng key này cũng phải đổi).
3. Seal lại bằng `scripts/seal-env.sh` cho `livekit-server` và `syncflow-room`, commit `sealed-secret.yaml`.
4. Sau khi ArgoCD sync, restart: `kubectl -n livekit-server rollout restart deploy/prod-livekit-server && kubectl -n syncflow-room rollout restart deploy/prod-syncflow-room`.
5. Kiểm tra lại mục 6.2.
