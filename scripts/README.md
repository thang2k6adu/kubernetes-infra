# STEP 1 – Check Dependencies

## Mục tiêu

Đảm bảo môi trường đủ công cụ để script chạy an toàn.

## Input

* Hệ thống hiện tại (PowerShell environment)

## Xử lý

1. Kiểm tra module:

   * `ConvertFrom-Yaml` (powershell-yaml)
2. Kiểm tra binary:

   * `kubectl`
   * `kubeseal`
3. Nếu thiếu bất kỳ dependency nào → `throw error` → `exit 1`

## Output

* Nếu hợp lệ: tiếp tục script
* Nếu thiếu: script dừng với message lỗi rõ ràng

---

# STEP 2 – Locate Project Root

## Mục tiêu

Xác định thư mục gốc của project (rootDir).

## Input

* Thư mục hiện tại: `Get-Location`

## Xử lý

1. Gọi hàm `Get-ProjectRoot`
2. Duyệt ngược lên từng thư mục cha
3. Kiểm tra điều kiện:

   * tồn tại file `.gitignore`
4. Khi tìm thấy → gán làm `$rootDir`

## Output

* `$rootDir` (đường dẫn project root)
* Nếu không tìm thấy → throw error → exit

---

# STEP 3 – Service Selection

## Mục tiêu

Xác định service cần thao tác.

## Input

* `$rootDir/services/`

## Xử lý

1. Quét các thư mục con trong:

   ```
   <rootDir>/services/
   ```
2. Lấy danh sách `availableServices`
3. User nhập `serviceName`
4. Validate:

   ```
   services/<serviceName> tồn tại
   ```
5. Đọc file:

   ```
   services/<serviceName>/service.yaml
   ```
6. In ra thông tin cơ bản (name, releaseName, chartRepo, …)

## Output

* `$serviceName`
* `$servicePath = services/<serviceName>`
* `$serviceConfig` (object từ service.yaml)

---

# STEP 4 – Cluster Selection

## Mục tiêu

Xác định cluster target để deploy.

## Input

* `$rootDir`

## Xử lý

1. Quét các thư mục:

   ```
   cluster-*
   ```

   ví dụ:

   * cluster-dev
   * cluster-staging
   * cluster-prod
2. Hiển thị danh sách cluster
3. User nhập `clusterName`
4. Validate tồn tại:

   ```
   <rootDir>/<clusterName>
   ```

## Output

* `$clusterName`
* `$clusterPath = <rootDir>/<clusterName>`

---

# STEP 5 – Certificate Selection (kubeseal cert)

## Mục tiêu

Chọn certificate để seal secret.

## Input

* `$rootDir`

## Xử lý

1. Tìm tất cả file:

   ```
   *.pem
   ```

   trong `$rootDir`
2. Nếu không có file nào → throw error
3. Nếu có:

   * 1 file → auto select
   * nhiều file → user chọn theo index
4. Validate file tồn tại

## Output

* `$certPath` (đường dẫn file .pem hợp lệ)

---

# STEP 6 – Generate Tenant Folder (gen-folder)

## Mục tiêu

Tạo skeleton tenant cho service trong cluster.

## Input

* `$serviceName`
* `$clusterName`
* `services/<serviceName>/service.yaml`
* `$rootDir`

## Xử lý

1. Đứng tại:

   ```
   services/<serviceName>
   ```
2. Đọc `service.yaml`
3. Xác định:

   ```
   rootDir
   clusterPath = <rootDir>/<clusterName>
   tenantDir = <clusterPath>/tenants/<serviceName>
   ```
4. Tạo thư mục:

   ```
   tenants/<serviceName>
   ```
5. Sinh:

   * `namespace.yaml` (theo service name)
   * `kustomization.yaml` (theo releaseName, chartRepo, version, values.yaml)

## Output

```
cluster-xxx/
  tenants/
    <service-name>/
      namespace.yaml
      kustomization.yaml
```

---

# STEP 7 – Generate values.yaml (gen-values)

## Mục tiêu

Sinh file values.yaml cho Helm chart.

## Input

* `services/<service-name>/service.yaml`
* `$rootDir`
* `$clusterName`

## Xử lý

1. Đứng tại `services/<project>`
2. Đọc `service.yaml`
3. Xác định:

   ```
   rootDir
   clusterDir
   tenantDir
   ```
4. Lấy từng giá trị config (có default)
5. Ghép thành template `values.yaml`
6. Ghi file vào tenantDir

## Output

```
cluster-xxx/
  tenants/<service>/
    values.yaml
```

---

# STEP 8 – Seal Secret & Generate ConfigMap (seal-env)

## Mục tiêu

Chuyển `.env` thành ConfigMap + SealedSecret an toàn cho GitOps.

## Input

* `services/<project>/.env`
* `services/<project>/secrets.whitelist`
* `$certPath`
* `$tenantDir`
* `kustomization.yaml`

## Xử lý

1. Đứng ở `services/<project>`
2. Đọc `.env` + `secrets.whitelist`
3. Phân loại:

   * config variables
   * secret variables
4. Tạo ConfigMap YAML (kubectl)
5. Tạo Secret YAML (kubectl)
6. Seal Secret bằng `kubeseal + cert`
7. Update `kustomization.yaml` thêm:

   ```
   configmap.yaml
   sealed-secret.yaml
   ```
8. Xóa file tạm

## Output

```
cluster-xxx/
  tenants/<service>/
    configmap.yaml
    sealed-secret.yaml
    kustomization.yaml (updated)
```

---

# Tổng kết ngắn gọn (pipeline)

```
STEP 1: Check tools
STEP 2: Find rootDir
STEP 3: Select service
STEP 4: Select cluster
STEP 5: Select cert
STEP 6: Gen tenant folder
STEP 7: Gen values.yaml
STEP 8: Seal env -> configmap + sealed-secret
```
