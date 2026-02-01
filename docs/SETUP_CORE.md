# K8S Dashboard

## 1. Thành phần cấu hình

### 1.1. ClusterRole: dashboard-admin

```yaml
kind: ClusterRole
metadata:
  name: dashboard-admin
```

ClusterRole định nghĩa quyền truy cập cho Dashboard.

#### a. Core resources (apiGroups: [""])

Quyền với:
- pods, pods/log
- services, namespaces
- configmaps, secrets
- pvc, events, endpoints, nodes

Verbs: ["get", "list", "watch", "create", "update", "delete"]

→ Dashboard có toàn quyền CRUD tài nguyên core.

#### b. Workloads (apps)

(resource để chạy và quản lý các pod, ko phải network, storage, config mà là để vận hành)

- deployments
- replicasets
- statefulsets
- daemonsets

Cho phép Dashboard:
- Tạo / sửa / xoá workload
- Xem trạng thái rollout

#### c. Batch jobs (batch, là lô, chạy kiểu theo lô, chạy xong tắt luôn)

- jobs
- cronjobs

Cho phép: Quản lý Job & CronJob

#### d. Networking

```yaml
apiGroups: ["networking.k8s.io"]
resources:
  - ingresses
```

Cho phép: Xem và chỉnh sửa Ingress

#### e. Metrics

```yaml
apiGroups: ["metrics.k8s.io"]
resources:
  - pods
  - nodes
verbs: ["get", "list", "watch"]
```

Cho phép Dashboard hiển thị:
- CPU / Memory usage của Pod và Node
- (Yêu cầu Metrics Server hoặc Prometheus Adapter hoạt động)

### 1.2. ServiceAccount

```yaml
kind: ServiceAccount
name: kubernetes-dashboard-admin
namespace: kubernetes-dashboard
```

ServiceAccount dùng để:
- Đăng nhập Dashboard bằng token
- Gắn quyền RBAC

### 1.3. ClusterRoleBinding

```yaml
kind: ClusterRoleBinding
name: kubernetes-dashboard-admin
```

Liên kết:
- ClusterRole: dashboard-admin
- ServiceAccount: kubernetes-dashboard-admin

→ ServiceAccount có toàn quyền được định nghĩa trong ClusterRole trên toàn cluster.

## 2. Kustomization

```yaml
resources:
  - recommended.yaml
  - kubernetes-dashboard-sa.yaml
  - kubernetes-dashboard-rbac.yaml
```

Ý nghĩa:
- `recommended.yaml` → Deploy Kubernetes Dashboard chính thức từ GitHub
- `kubernetes-dashboard-sa.yaml` → Tạo ServiceAccount admin
- `kubernetes-dashboard-rbac.yaml` → Tạo ClusterRole + Binding

Kustomize gom tất cả thành một bộ triển khai duy nhất.

## 3. Kiểm tra

```bash
kubectl -n kubernetes-dashboard get pods
```

## 4. Lấy token đăng nhập Dashboard

```bash
kubectl -n kubernetes-dashboard create token kubernetes-dashboard-admin
```

Dán token vào Dashboard Login Screen.

```bash
kubectl -n kubernetes-dashboard port-forward --address 0.0.0.0 service/kubernetes-dashboard 8443:443
```

## 5. Lưu ý bảo mật

Cấu hình này cấp quyền rất cao:

Có thể:
- Xoá namespace
- Đọc secrets
- Tạo workload bất kỳ
- Xem logs toàn cluster

Khuyến nghị:

Chỉ dùng cho:
- Dev / lab
- Cluster nội bộ

Production nên:
- Tạo Role theo namespace
- Không dùng ClusterRole full quyền

---

# Triển khai kube-prometheus-stack bằng Kustomize + Helm

## 1. kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: monitoring

resources:
  - monitoring-ns.yaml

helmCharts:
  - name: kube-prometheus-stack
    repo: https://prometheus-community.github.io/helm-charts
    version: 61.3.2
    releaseName: monitoring
    namespace: monitoring
    includeCRDs: true
    valuesFile: values.yaml
```

### Giải thích:

- `namespace: monitoring` → Mặc định tất cả resource được deploy vào namespace monitoring.
- `resources: monitoring-ns.yaml` → Khai báo manifest tạo namespace trước khi cài chart.
- `helmCharts:` Dùng Helm chart kube-prometheus-stack thông qua Kustomize:
  - `version: 61.3.2`: phiên bản chart
  - `includeCRDs: true`: cài CRDs của Prometheus Operator
  - `valuesFile: values.yaml`: file cấu hình tùy chỉnh

## 2. monitoring-ns.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    name: monitoring
```

Chức năng:
- Tạo namespace monitoring để chứa toàn bộ stack monitoring.
- Dùng nhãn `name: monitoring` để dễ quản lý và filter.

## 3. values.yaml

### 3.1. Tắt các thành phần không dùng

```yaml
grafana:
  enabled: false

alertmanager:
  enabled: false

defaultRules:
  create: false
```

Giải thích:
- Tắt Grafana → không triển khai UI Grafana.
- Tắt Alertmanager → không gửi alert.
- Tắt default alert rules → tránh tạo hàng trăm rule mặc định, tiết kiệm RAM/CPU.

### 3.2. Bật các exporter cần thiết

```yaml
nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true

prometheusOperator:
  enabled: true
```

Giải thích:
- `nodeExporter`: thu thập metrics của node (CPU, RAM, disk, network).
- `kubeStateMetrics`: thu thập metrics trạng thái Kubernetes object (pod, deployment, service, …).
- `prometheusOperator`: controller quản lý Prometheus CRD.

### 3.3. Cấu hình Prometheus

```yaml
prometheus:
  enabled: true
  prometheusSpec:
    retention: 6h
```

Giải thích:
- Bật Prometheus server.
- `retention: 6h` → chỉ lưu metrics trong 6 giờ (giảm dung lượng storage).

### 3.4. Resource limits

```yaml
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 300m
        memory: 512Mi
```

Giải thích:

Giới hạn tài nguyên cho Prometheus:
- Request: CPU 100m, RAM 256Mi
- Limit: CPU 300m, RAM 512Mi

→ phù hợp cluster nhỏ, tránh Prometheus chiếm hết tài nguyên node.

### 3.5. Storage

```yaml
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi
```

Giải thích:
- Tạo PersistentVolumeClaim cho Prometheus
- Dung lượng: 1Gi
- Kiểu truy cập: ReadWriteOnce

→ lưu dữ liệu metrics trên disk thay vì memory.

## 4. Cách triển khai

Chạy lệnh:

```bash
kustomize build --enable-helm . | kubectl apply -f -
```

Hoặc với ArgoCD (GitOps):
- Khai báo Application trỏ tới thư mục chứa kustomization.yaml
- ArgoCD sẽ render Helm chart và apply vào cluster.

## 5. Những điểm cần lưu ý

**Không có Grafana:**

Muốn xem metrics phải:
- port-forward Prometheus hoặc
- cài Grafana riêng

**Không có Alertmanager:**

Không có cảnh báo khi node/pod lỗi

---

# Triển khai Ingress NGINX bằng Kustomize + Helm

## 1. Cấu trúc file

### 1.1. kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ingress-nginx

resources:
  - nginx-ingress-ns.yaml

helmCharts:
  - name: ingress-nginx
    repo: https://kubernetes.github.io/ingress-nginx
    version: 4.10.0
    releaseName: ingress-nginx
    namespace: ingress-nginx
    valuesFile: values.yaml
```

Giải thích:
- Deploy Helm chart ingress-nginx version 4.10.0
- Namespace mặc định: ingress-nginx
- File values.yaml chứa toàn bộ cấu hình custom
- nginx-ingress-ns.yaml dùng để tạo namespace trước

### 1.2. nginx-ingress-ns.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ingress-nginx
```

Chức năng:
- Tạo namespace riêng cho Ingress Controller
- Giúp cô lập tài nguyên ingress với workload khác

## 2. Cấu hình controller (values.yaml)

### 2.1. Replica & IngressClass

```yaml
controller:
  replicaCount: 2
```

Chạy 2 pod ingress controller để đảm bảo HA cơ bản.

```yaml
  ingressClassResource:
    enabled: true
    default: true
    name: nginx
```

- Tạo IngressClass tên nginx
- Đặt làm mặc định cho toàn cluster
- IngressClass dùng để xác định Ingress resource sẽ được xử lý bởi controller nào.

#### Vấn đề nếu không có IngressClass

Trong cluster có thể có nhiều Ingress Controller:
- nginx
- traefik
- istio
- haproxy

Nếu không có IngressClass:
→ Tất cả controller đều có thể cố xử lý cùng một Ingress
→ xung đột, route sai, lỗi khó debug.

#### IngressClass hoạt động như thế nào

Bạn khai báo một IngressClass:

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
spec:
  controller: k8s.io/ingress-nginx
```

Ingress Controller nginx sẽ chỉ quản lý các Ingress có:

```yaml
spec:
  ingressClassName: nginx
```

Ví dụ:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
spec:
  ingressClassName: nginx
  rules:
    - host: app.example.com
```

Ingress không cần chỉ định ingressClassName vẫn dùng nginx (nếu để default)

### 2.2. Kiểu workload

```yaml
  kind: Deployment
```

- Chạy controller dưới dạng Deployment
- Phù hợp autoscaling và rolling update

### 2.3. Service expose ra ngoài (NodePort)

```yaml
  service:
    enabled: true
    type: NodePort
    externalTrafficPolicy: Local
    ports:
      http: 80
      https: 443
    nodePorts:
      http: 30080
      https: 30443
```

Giải thích:
- Expose HTTP qua port 30080
- Expose HTTPS qua port 30443
- `externalTrafficPolicy: Local`:
  - Giữ IP client thật
  - Chỉ route traffic tới node có pod ingress

Truy cập từ ngoài:
- `http://NODE_IP:30080`
- `https://NODE_IP:30443`

### 2.4. Resource & Autoscaling

```yaml
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
```

- Đảm bảo mỗi pod có tài nguyên tối thiểu
- Tránh bị evict khi node thiếu RAM

```yaml
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
    targetCPUUtilizationPercentage: 60
```

- Bật HPA
- Scale từ 2 → 5 pod
- Scale khi CPU > 60%

### 2.5. NGINX config (proxy & header)

(Nếu không có cấu hình này, NGINX sẽ chỉ thấy IP của proxy (ví dụ node, LB), không phải IP người dùng thật.)

**VD:** Client → Proxy → Ingress

Ingress chỉ thấy IP của Proxy: 👉 10.0.0.5

Ingress đọc header: `X-Forwarded-For: 1.2.3.4` → biết IP thật của người dùng là: 👉 1.2.3.4

"Hãy lấy IP người dùng từ header X-Forwarded-For do proxy gửi tới."

```yaml
  config:
    use-forwarded-headers: "true"
    proxy-real-ip-cidr: "0.0.0.0/0"
    real-ip-header: "X-Forwarded-For"
```

**CIDR** là cách viết gọn một dải IP bằng dạng IP/số-bit: `192.168.0.1/24` là 1 CIDR

- Lấy IP thật của client từ header
- `proxy-real-ip-cidr`: là cidr (dải ip) của proxy mà nginx tin để lấy forwarded client ip
- Phù hợp khi có proxy phía trước

```yaml
    proxy-body-size: "50m"
```

Cho phép upload file tối đa 50MB

```yaml
    proxy-read-timeout: "600"
    proxy-send-timeout: "600"
```

Timeout 10 phút cho request dài (upload, API chậm)

```yaml
    worker-shutdown-timeout: "240s"
```

Cho phép request đang xử lý hoàn thành khi pod shutdown

```yaml
    enable-underscores-in-headers: "true"
```

Cho phép header có dấu _ (Mặc định NGINX không cho header có dấu gạch dưới _ vì lý do bảo mật và chuẩn HTTP.)

Ví dụ header bị chặn (SAU KHI BẬT SẼ ĐƯỢC):
- `X_User_Id: 123`
- `auth_token: abc`

### 2.6. Security

```yaml
  allowSnippetAnnotations: false
```

Không cho dùng annotation `nginx.ingress.kubernetes.io/server-snippet` → chèn rule độc hại

```yaml
nginx.ingress.kubernetes.io/server-snippet: |
  lua_package_path "/tmp/?.lua;;";
  access_by_lua_file /tmp/malicious.lua;
```

→ Hãy cho phép load file Lua từ thư mục /tmp. Mỗi request đi vào server này, hãy chạy file /tmp/malicious.lua trước khi xử lý tiếp.

Client request → Ingress NGINX → chạy file malicious.lua → rồi mới forward tới app

### 2.7. Metrics & Prometheus

```yaml
  metrics:
    enabled: true
    service:
      enabled: true
    serviceMonitor:
      enabled: true
```

Bật endpoint metrics `/metrics`

Ingress sẽ mở URL: `/metrics`

Tại đây có số liệu như:
- số request
- response time
- status code (200, 404, 500…)
- số connection
- lỗi 4xx, 5xx

Tạo ServiceMonitor để Prometheus scrape tự động

Phù hợp với kube-prometheus-stack

### 2.8. PodDisruptionBudget

```yaml
  podDisruptionBudget:
    enabled: true
    minAvailable: 1
```

- Luôn giữ ít nhất 1 pod ingress hoạt động
- Tránh downtime khi node drain / upgrade

### 2.9. Affinity (chống dồn pod 1 node)
~
```yaml
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
```

- Tránh schedule 2 ingress pod trên cùng node
- Tăng tính sẵn sàng

### 2.10. Graceful shutdown

```yaml
  terminationGracePeriodSeconds: 300
```

Cho pod 5 phút để xử lý request trước khi kill

```yaml
  lifecycle:
    preStop:
      exec:
        command:
          - /wait-shutdown
```

Script chờ nginx xử lý xong connection

## 3. Default Backend

```yaml
defaultBackend:
  enabled: true
```

- Tạo service backend mặc định
- Trả về 404 khi request không match ingress rule

## 4. Cách triển khai

```bash
kustomize build --enable-helm . | kubectl apply -f -
```

Hoặc với ArgoCD:
- Application trỏ tới thư mục chứa kustomization.yaml
- ArgoCD render Helm chart và sync vào cluster

## 5. Khi nào nên dùng cấu hình này

Phù hợp:
- Cluster on-premise / k3s / lab
- Muốn autoscaling ingress
- Có Prometheus scrape metrics