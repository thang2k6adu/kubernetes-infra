# Hệ thống Deployment Configuration - Documentation

## Tổng quan
Hệ thống này quản lý cấu hình deployment Kubernetes theo mô hình GitOps, sử dụng ArgoCD để tự động deploy các service từ cấu hình được version control.

## Cấu trúc thư mục
```
project-root/
├── services/                          # Service configurations
│   └── [service-name]/
│       ├── values.yaml               # Main service configuration (source of truth)
│       ├── .env                      # Environment variables
│       └── secrets.whitelist        # List of secret variables
├── cluster-[name]/                   # Cluster configurations
│   ├── cluster-config.yaml          # Cluster directory structure
│   ├── services/                    # Service configs within cluster
│   └── tenants/                     # Generated deployment manifests
└── scripts/
    ├── deploy.sh                    # Main deployment script
    ├── gen-folder.sh               # Generate tenant folder
    ├── gen-values.sh               # Copy values.yaml
    └── seal-env.sh                 # Seal environment variables
```

## STEP 1 – Kiểm tra phụ thuộc

### Mục tiêu
Đảm bảo tất cả công cụ cần thiết đã được cài đặt.

### Xử lý
1. Kiểm tra các công cụ bắt buộc:
   - `yq` (YAML processor)
   - `kubectl` (Kubernetes CLI)
   - `kubeseal` (Sealed Secrets encryption)
   - `kustomize` (Kustomization tool)

2. Nếu thiếu bất kỳ công cụ nào:
   - Hiển thị thông báo lỗi chi tiết
   - Thoát với mã lỗi 1

### Output
- Tiếp tục nếu tất cả công cụ có sẵn
- Dừng script nếu thiếu công cụ

## STEP 2 – Xác định thư mục gốc dự án

### Mục tiêu
Xác định thư mục gốc của dự án để định vị các thư mục cluster.

### Xử lý
1. Duyệt từ thư mục hiện tại lên các thư mục cha
2. Tìm kiếm:
   - Thư mục chứa file `.gitignore` HOẶC
   - Thư mục chứa các thư mục `cluster-*`

3. Nếu không tìm thấy:
   - Yêu cầu người dùng nhập đường dẫn thủ công
   - Validate đường dẫn hợp lệ

### Output
- `$rootDir`: Đường dẫn thư mục gốc dự án
- Thoát nếu không xác định được

## STEP 3 – Chọn Cluster

### Mục tiêu
Chọn cluster target để deploy service.

### Xử lý
1. Tìm tất cả các thư mục `cluster-*` trong `$rootDir`
2. Hiển thị danh sách cluster có sẵn
3. Người dùng nhập tên cluster:
   - Có thể nhập trực tiếp
   - Hoặc chọn từ danh sách

4. Validate:
   - Cluster directory tồn tại
   - File `cluster-config.yaml` tồn tại

### Output
- `$ClusterName`: Tên cluster đã chọn
- `$clusterPath`: Đường dẫn đến cluster directory

## STEP 4 – Đọc cấu hình cluster

### Mục tiêu
Đọc cấu trúc thư mục từ file `cluster-config.yaml`.

### Xử lý
1. Đọc file `$clusterPath/cluster-config.yaml`
2. Trích xuất các đường dẫn:
   - `servicesPath`: Đường dẫn đến service configurations
   - `tenantsPath`: Đường dẫn đến generated tenants
   - `certPath`: Đường dẫn đến certificate file

3. Xây dựng đường dẫn đầy đủ

### Output
- `$clusterServicesFullPath`: Đường dẫn đầy đủ đến service configs
- `$clusterTenantsFullPath`: Đường dẫn đầy đủ đến tenants
- `$clusterCertFullPath`: Đường dẫn đầy đủ đến certificate

## STEP 5 – Chọn Service

### Mục tiêu
Chọn service cần deploy từ danh sách có sẵn trong cluster.

### Xử lý
1. Liệt kê tất cả các service trong `$clusterServicesFullPath`
2. Hiển thị danh sách service
3. Người dùng nhập tên service
4. Validate:
   - Service directory tồn tại
   - File `values.yaml` tồn tại trong service directory

### Output
- `$ProjectName`: Tên service đã chọn
- `$serviceDir`: Đường dẫn đến service directory

## STEP 6 – Xác định tên service

### Mục tiêu
Xác định tên service cuối cùng từ file `values.yaml`.

### Xử lý
1. Đọc file `$serviceDir/values.yaml`
2. Trích xuất theo thứ tự ưu tiên:
   - `nameOverride`: Nếu có
   - `fullnameOverride`: Nếu không có `nameOverride`
   - Tên thư mục: Nếu cả hai đều không có

3. Validate tên service không rỗng

### Output
- `$serviceName`: Tên service đã xác định
- `$namespace`: Namespace (mặc định bằng tên service)

## STEP 7 – Chọn Template

### Mục tiêu
Chọn template để generate deployment manifests.

### Xử lý
1. Liệt kê tất cả các template trong `templates/` directory
2. Hiển thị danh sách template có sẵn
3. Người dùng chọn template:
   - Có thể nhập trực tiếp
   - Hoặc sử dụng giá trị mặc định "dev"

4. Validate:
   - Template directory tồn tại
   - Có file `namespace.tpl.yaml` và `kustomization.tpl.yaml`

### Output
- `$TemplateName`: Tên template đã chọn
- `$templateDir`: Đường dẫn đến template directory

## STEP 8 – Chọn Certificate

### Mục tiêu
Chọn certificate để encrypt Sealed Secrets.

### Xử lý
1. Ưu tiên sử dụng certificate từ cluster config
2. Nếu không có trong cluster config:
   - Kiểm tra certificate từ tham số `--CertPath`
   - Hoặc yêu cầu người dùng chỉ định

3. Validate:
   - File certificate tồn tại
   - Định dạng hợp lệ (PEM)

### Output
- `$CertPath`: Đường dẫn đầy đủ đến certificate file

## STEP 9 – Thực thi Deployment

### Mục tiêu
Generate tất cả các file cần thiết cho deployment.

### Xử lý
#### 9.1 – Generate tenant folder structure
1. Gọi `gen-folder.sh` với các tham số:
   - `--RootDir`
   - `--ClusterName`
   - `--TenantsPath`
   - `--ProjectName`
   - `--TemplateName`

2. Tạo thư mục tenant và generate:
   - `namespace.yaml`
   - `kustomization.yaml`
   - Copy `values.yaml`

#### 9.2 – Copy values.yaml
1. Gọi `gen-values.sh` để copy `values.yaml` từ service directory sang tenant directory

#### 9.3 – Seal environment variables
1. Gọi `seal-env.sh` để:
   - Đọc `.env` và `secrets.whitelist`
   - Generate `configmap.yaml` và `sealed-secret.yaml`
   - Update `kustomization.yaml`

### Output
- Thư mục tenant hoàn chỉnh với tất cả các file cần thiết

## STEP 10 – Tổng kết

### Mục tiêu
Hiển thị thông tin deployment đã được tạo.

### Xử lý
1. Liệt kê tất cả các file đã generate
2. Hiển thị thông tin chi tiết:
   - Tên service
   - Cluster target
   - Namespace
   - Template sử dụng
   - Đường dẫn output

3. Hiển thị kích thước và trạng thái của từng file

### Output
- Thông tin deployment summary
- Danh sách file đã generate với kích thước

## Workflow tổng quát

```
1. Check Dependencies → 2. Find Project Root → 3. Select Cluster → 4. Read Cluster Config
↓
5. Select Service → 6. Determine Service Name → 7. Select Template → 8. Select Certificate
↓
9.1 Generate Tenant Folder → 9.2 Copy values.yaml → 9.3 Seal Environment Variables
↓
10. Display Deployment Summary
```

## Cấu hình file values.yaml mẫu

```yaml
nameOverride: "livekit-server"
fullnameOverride: ""

replicaCount: 1

image:
  repository: livekit/livekit-server
  tag: "v1.6.0"
  pullPolicy: IfNotPresent

# ... các cấu hình khác
```

## File hỗ trợ trong service directory
1. **values.yaml** (bắt buộc): Cấu hình chính của service
2. **.env** (tùy chọn): Environment variables
3. **secrets.whitelist** (tùy chọn): Danh sách biến môi trường cần encrypt

## Các mode chạy
1. **Interactive mode**: Chạy script không có tham số, nhập tương tác
2. **Parameter mode**: Chỉ định tham số qua command line
3. **Dry-run mode**: Chỉ hiển thị các lệnh sẽ thực thi, không tạo file

## Security Notes
- Secret values được encrypt với kubeseal
- Chỉ cluster target mới có thể decrypt
- `sealed-secret.yaml` an toàn để commit vào Git
- Không bao giờ commit file `.env` gốc