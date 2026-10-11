# Các mục phải sửa

## 1. Trỏ đúng image backend
```yaml
image:
  repository: ghcr.io/thang2k6adu/pp191225-be/be:develop
  tag: ""
```

## 2. Port mapping

Phải khớp với port app chạy trong container. Ví dụ app NodeJS chạy port 3000:
```yaml
service:
  port: 80
  targetPort: 3000
```

## 3. Biến môi trường (env)
```yaml
env:
  - name: PORT
    value: "3000"
  - name: DB_HOST
    value: "postgres"
  - name: REDIS_HOST
    value: "redis"
```

## 4. Bật ingress
```yaml
ingress:
  enabled: true
  hosts:
    - host: api.user.example.com
```

## 5. Health check (probes)

Phải đúng endpoint của app:
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: http
```

## 6. ConfigMap / Secrets (nếu app dùng)

**ConfigMap:**
```yaml
configMap:
  enabled: true
  data:
    application.yml: |
      db.host=postgres
```

**Secrets:**
```yaml
secrets:
  enabled: true
  data:
    DATABASE_PASSWORD: xxx
```

## 7. Volume mounts (nếu app cần ghi file)

Nếu app ghi log/cache:
```yaml
volumeMounts:
  - name: cache
    mountPath: /app/cache
```

---

## Muốn thành Helm repo chuẩn

Bạn cần:
- `backend-service-0.1.0.tgz`
- `index.yaml`

### How to deploy

Trong `/c/workspace` lưu ý là phải có 1 thư mục chứa chart

**VD:**
```bash
helm-charts/
  backend-service-0.1.0.tgz
```

**Helm package:**
```bash
helm package backend-service
```

**Kết quả:**
```
backend-service-0.1.0.tgz
```

### Tạo index.yaml (helm repo)
```bash
helm repo index . --url https://thang2k6adu.github.io/backend-service-charts
```

### Push lên GitHub (branch gh-pages)
```bash
git add .
git commit -m "publish helm chart backend-service-chart 0.1.0"
git push origin gh-pages
```

**URL repo Helm sẽ là:**
```
https://thang2k6adu.github.io/backend-service-charts
```

### Bật GitHub Pages

Vào repo GitHub của bạn → **Settings** → **Pages**

Chọn:
- **Source:** Deploy from a branch
- **Branch:** gh-pages
- **Folder:** / (root)