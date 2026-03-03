# Lưu ý trước khi deploy LiveKit

## Cấu hình mạng
```yaml
rtc:
  use_external_ip: true
  external_ip: "13.212.50.46"  # Phải sửa thành Public IP thật của server
```

## API Keys

- Sửa `keys.yaml` trong file `.env` với format: `devkey: "9f3c1a6b8d2e4f7a9c1d3e5f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5"`

## Redis và Replicas

**Nếu dùng 2 replicas trở lên:** Redis phải hoạt động
- Tạo Redis password trong `.env`
- Sửa `address`, `passwordSecret` và `passwordSecretKey` trong `values.yaml`

**Nếu chỉ 1 replica:** Có thể tạm tắt Redis

## Cấu hình hiện tại

- Phù hợp với môi trường có reverse proxy/LB trước cluster
- Để dùng trực tiếp trên cloud: Đổi `service.type` thành `LoadBalancer`

## Production checklist

### Hiện tại (dev/test):
- 1 replica
- Redis disabled (chưa High Availability)
- Resources: 500MB RAM (đủ cho dev/test)
- LiveKit cần CPU nhiều hơn RAM

### Chuẩn production cần:
- Tăng replicas (ít nhất 2 cho HA)
- Bật Redis cho state sharing
- Bật HPA (Horizontal Pod Autoscaling)
- Bật autoscaling
- Tăng resources (CPU quan trọng hơn RAM)
- Bật TURN server để hỗ trợ 4G, mạng công ty, NAT strict

## TURN Server

- Cần thiết cho các mạng restrictive (4G, corporate networks)
- Cấu hình domain, TLS port, UDP port, secret
- Yêu cầu LoadBalancer hoặc NodePort cho TURN traffic

## Tài liệu bổ sung

Để xây hạ tầng LiveKit:
- Đọc `OPEN_PORT.md` để mở port cần thiết cho hoạt động
- Đọc `MODIFY_RESERVE_PROXY.md` để biết setup riêng cho LiveKit (rất khác với dịch vụ thông thường)

## Quản lý API Keys an toàn

Để LiveKit chạy được, nó đọc dev key và dev key secret ở `values.yaml` hoặc ConfigMap. Tuy nhiên điều này rất rủi ro.