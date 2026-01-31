# Kubernetes Monitoring & Checking Guide

## Check Kubernetes Dashboard

### Kiểm tra pod & service

```shell
kubectl -n kubernetes-dashboard get pods
kubectl -n kubernetes-dashboard get svc
```

### Kiểm tra RBAC

```shell
kubectl get clusterrole dashboard-admin
kubectl get clusterrolebinding kubernetes-dashboard-admin
kubectl -n kubernetes-dashboard get sa kubernetes-dashboard-admin
```

### Lấy token đăng nhập

```shell
kubectl -n kubernetes-dashboard create token kubernetes-dashboard-admin
```

### Port-forward Dashboard (nhớ mở firewall)

```shell
kubectl -n kubernetes-dashboard port-forward --address 0.0.0.0 service/kubernetes-dashboard 8443:443
```

### Check dashboard

```shell
sudo ufw allow 8443
```

Access at: https://192.168.0.50:8443/

### Disable port if done

```shell
sudo ufw delete allow 8443
```

---

## Check kube-prometheus-stack

### Kiểm tra pod

```shell
kubectl -n monitoring get pods
```

### Kiểm tra CRDs

```shell
kubectl get crd | grep prometheus
kubectl get crd | grep servicemonitor
```

### Kiểm tra Prometheus

```shell
kubectl -n monitoring get prometheus
kubectl -n monitoring get svc
```

### Kiểm tra PVC

```shell
kubectl -n monitoring get pvc
```

### Port-forward Prometheus UI (nhớ mở firewall)

```shell
kubectl -n monitoring port-forward --address 0.0.0.0 svc/monitoring-kube-prometheus-prometheus 9090:9090
```

### Mở:

http://localhost:9090

---

## Check Ingress NGINX

### Kiểm tra namespace & pod

```shell
kubectl -n ingress-nginx get pods
kubectl -n ingress-nginx get svc
```

### Kiểm tra IngressClass

```shell
kubectl get ingressclass
```

### Kiểm tra HPA

```shell
kubectl -n ingress-nginx get hpa
```

### Kiểm tra ServiceMonitor (metrics)

```shell
kubectl -n ingress-nginx get servicemonitor
```

### Test metrics endpoint

```shell
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller-metrics 10254:10254
curl http://localhost:10254/metrics
```