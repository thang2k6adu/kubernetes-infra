# Deploy frontend: Web-Admin & Teacher-Studio lên cluster-prod

Hai frontend đi đúng đường của backend Sync Flow, không có gì đặc biệt:

```
git push main (repo frontend)
  └─ GitHub Actions: lint + build → docker build → push Nexus
       registry.kruzetech.dev/<app>:git-<sha 40 hex>
            └─ argocd-image-updater (quét 2 phút/lần) thấy tag mới
                 └─ commit .argocd-source-<app>.yaml vào cluster-prod/tenants/<app>/
                      └─ ArgoCD sync → pod mới chạy
Người dùng → DNS → nginx trên VPS (TLS) → ingress-nginx trong cluster → Service → Pod
```

| | Web-Admin | Teacher-Studio |
|---|---|---|
| Repo | `tongviet-hub/Sync_Flow_Web-Admin` | `tongviet-hub/Sync_Flow_Teacher-Studio` |
| Loại | SPA Vite, serve bằng nginx-unprivileged | Next.js standalone (`node server.js`) |
| Image | `registry.kruzetech.dev/syncflow-web-admin` | `registry.kruzetech.dev/syncflow-teacher-studio` |
| Port | 8080 | 3000 |
| Health | `GET /healthz` | `GET /healthz` |
| Domain | `syncflow-admin.kruzetech.dev` | `syncflow-teacher.kruzetech.dev` |
| Config cluster | `cluster-prod/services/syncflow-web-admin/` | `cluster-prod/services/syncflow-teacher-studio/` |

Đổi domain: sửa `ingress.hosts[0].host` trong `values.yaml` **và** dùng đúng tên đó ở bước 4.

---

## Bước 1 — Khai secrets cho GitHub Actions (mỗi repo 1 lần)

Vào repo trên GitHub → **Settings → Secrets and variables → Actions**.

Tab **Variables** → *New repository variable*:

| Tên | Giá trị |
|---|---|
| `IMAGE_REGISTRY` | `registry.kruzetech.dev` |
| `VITE_API_BASE_URL` | *(chỉ Web-Admin, tuỳ chọn)* bỏ trống thì dùng `https://syncflow-gateway.kruzetech.dev/api` |

Tab **Secrets** → *New repository secret*:

| Tên | Giá trị |
|---|---|
| `REGISTRY_USER` | tài khoản Nexus có quyền push (cùng tài khoản repo backend đang dùng) |
| `REGISTRY_TOKEN` | mật khẩu/token của tài khoản đó |

> Nếu 2 repo cùng org `tongviet-hub`, có thể khai 1 lần ở **Organization settings** thay vì từng repo.

## Bước 2 — Push code, lấy tag image đầu tiên

Commit + push lên `main`. Vào tab **Actions** của repo, đợi workflow `CI - syncflow-...` xanh cả 2 job
(`build-test`, `build-push-image`). Mở job `build-push-image` → bước *Push image* có dòng:

```
pushed: registry.kruzetech.dev/syncflow-web-admin:git-3f2a...(40 ký tự)
```

Copy phần `git-...` đó. (Hoặc lấy commit SHA đầy đủ: `git rev-parse HEAD`, thêm tiền tố `git-`.)

## Bước 3 — Tạo tenant trong repo kubernetes-infra

Cần: quyền push vào `thang2k6adu/kubernetes-infra`, và máy Linux/WSL (hoặc master node) có
`kubectl`, `kubeseal`, `gomplate`, `yq`. Script chỉ seal bằng `pub-cert.pem`, không cần kết nối cluster.

Làm cho từng app (ví dụ Web-Admin):

```bash
cd kubernetes-infra

# 3.1 Điền tag lấy ở bước 2 vào image.tag
nano cluster-prod/services/syncflow-web-admin/values.yaml

# 3.2 Tạo .env (đã gitignore) và điền tài khoản Nexus để sinh imagePullSecret
cp cluster-prod/services/syncflow-web-admin/.env.example cluster-prod/services/syncflow-web-admin/.env
nano cluster-prod/services/syncflow-web-admin/.env

# 3.3 Sinh tenant
./scripts/create-tenant.sh \
  --ClusterName cluster-prod \
  --ProjectName syncflow-web-admin \
  --TemplateName backend-prod \
  --CertPath cluster-prod/pub-cert.pem

# 3.4 Render thử, không lỗi là được
kubectl kustomize --enable-helm cluster-prod/tenants/syncflow-web-admin > /dev/null && echo OK
```

Lặp lại với `syncflow-teacher-studio`. Kết quả phải có:

```
cluster-prod/tenants/syncflow-web-admin/
  namespace.yaml  kustomization.yaml  values.yaml  configmap.yaml  registry-secret.yaml
```

(Không có `sealed-secret.yaml` là đúng: frontend không có secret runtime, `REGISTRY_*` đi vào `registry-secret.yaml`.)

Rồi commit + push:

```bash
git add cluster-prod/services/syncflow-web-admin cluster-prod/services/syncflow-teacher-studio \
        cluster-prod/tenants/syncflow-web-admin cluster-prod/tenants/syncflow-teacher-studio
git commit -m "feat(prod): add syncflow-web-admin & syncflow-teacher-studio tenants"
git push
```

ApplicationSet `tenants` tự quét `cluster-prod/tenants/*` nên tự sinh 2 Application mới, không khai gì thêm.

## Bước 4 — Trỏ domain

**4.1 DNS** — ở nơi quản lý DNS của `kruzetech.dev`, thêm 2 bản ghi `A` trỏ về IP public của VPS
(cùng IP với `syncflow-gateway.kruzetech.dev`):

| Type | Name | Value |
|---|---|---|
| A | `syncflow-admin` | `<IP VPS>` |
| A | `syncflow-teacher` | `<IP VPS>` |

Kiểm tra: `nslookup syncflow-admin.kruzetech.dev` ra đúng IP.

**4.2 Nginx + TLS trên VPS** — SSH vào VPS, chạy (script đã có sẵn, xem [ADD_DOMAIN.md](ADD_DOMAIN.md)):

```bash
sudo add-domain syncflow-admin.kruzetech.dev cluster-prod
sudo add-domain syncflow-teacher.kruzetech.dev cluster-prod
```

Script tự xin cert Let's Encrypt, nên DNS ở 4.1 phải trỏ đúng trước.

## Bước 5 — Kiểm tra

```bash
kubectl get applications -n argocd | grep -E 'web-admin|teacher'   # Synced + Healthy
kubectl get pods -n syncflow-web-admin
kubectl get pods -n syncflow-teacher-studio
curl https://syncflow-admin.kruzetech.dev/healthz     # ok
curl https://syncflow-teacher.kruzetech.dev/healthz   # ok
```

Mở `https://syncflow-admin.kruzetech.dev`, đăng nhập tài khoản ADMIN. F12 → Network: request phải đi tới
`https://syncflow-gateway.kruzetech.dev/api/...`.

Từ đây mỗi lần push `main` là tự lên prod sau ~2-5 phút, không phải làm lại bước nào.

---

## Gặp lỗi thì xem đâu

| Triệu chứng | Nguyên nhân hay gặp | Cách xử lý |
|---|---|---|
| Job `build-push-image` lỗi `IMAGE_REGISTRY not set` | Chưa khai Variable | Bước 1 |
| `unauthorized` khi push | Sai `REGISTRY_USER`/`REGISTRY_TOKEN` | Khai lại secret |
| Pod `ImagePullBackOff` | Tag trong `values.yaml` không tồn tại, hoặc thiếu `registry-secret.yaml` | `kubectl describe pod -n <ns> <pod>`; sửa tag, hoặc chạy `./scripts/seal-registry-creds.sh --ClusterName cluster-prod` |
| Pod `CrashLoopBackOff` | App chết khi khởi động | `kubectl logs -n <ns> deploy/prod-<app>` |
| Push code mới mà prod không đổi | Tag không khớp `git-<sha 40>` hoặc image-updater chưa quét | `kubectl logs -n argocd deploy/argocd-image-updater -f` |
| Web-Admin báo lỗi CORS | `CORS_ORIGIN` của gateway không cho domain admin | Thêm `https://syncflow-admin.kruzetech.dev` vào `CORS_ORIGIN` của `syncflow-gateway` (hiện đang `*`) |
| Web-Admin gọi sai URL API | `VITE_API_BASE_URL` nhúng lúc build | Sửa Variable ở bước 1 rồi re-run workflow — đổi env trên cluster **không** có tác dụng |
| `502`/`504` từ VPS | Pod chưa Ready hoặc ingress host sai | `kubectl get ingress -A \| grep syncflow` xem host khớp domain |
