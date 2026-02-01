cài kubeseal trên local

linux
curl -L https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.25.0/kubeseal-linux-amd64 -o kubeseal
chmod +x kubeseal
sudo mv kubeseal /usr/local/bin/

window
curl.exe -L https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.34.0/kubeseal-0.34.0-windows-amd64.tar.gz -o kubeseal.tar.gz

tar -xvf kubeseal.tar.gz

mkdir C:\kubeseal
move kubeseal.exe C:\kubeseal\
setx PATH "$env:PATH;C:\kubeseal"

check

kubeseal --version


lên cluster
tìm secret chứa certificate của sealedSecret

kubectl get secret -n kube-system | grep sealed

VD: sealed-secrets-keyjwxc2

gen key (tls.crt là pub key, tls.key là private key)
mkdir -p ~/sealed-secrets
kubectl get secret -n kube-system sealed-secrets-keyjwxc2 \
  -o jsonpath="{.data.tls\.crt}" | base64 -d > ~/sealed-secrets/pub-cert.pem

check
ls ~/sealed-secrets/pub-cert.pem


giờ copy key về máy
mkdir "$env:USERPROFILE\sealed-secrets" -Force; scp -P 8022 thang2k6adu@192.168.0.50:/home/thang2k6adu/sealed-secrets/pub-cert.pem "$env:USERPROFILE\sealed-secrets\pub-cert.pem"

Hướng dẫn tạo secret từ env (nhớ cài kubectl)

linux
./seal-env.sh <ENV_FILE> <SECRET_NAME> <NAMESPACE> <CERT_PATH>

VD
chmod +x seal-env.sh
cd cluster-dev/tenants/pp191225-api-service
../../../../seal-env.sh pp191225-api pp191225-secret ~/sealed-secrets/pub-cert.pem


window (powershell thường cấm chạy script, nhớ mở)
Cài kubectl window
winget install Kubernetes.kubectl

.\seal-env.ps1 <ENV_FILE> <SECRET_NAME> <NAMESPACE> <CERT_PATH>

VD
cd cluster-dev/tenants/pp191225-api-service
Remove-Item sealed-secret.yaml, configmap.yaml -Force
..\..\..\seal-env.ps1 pp191225-api pp191225-secret ~\sealed-secrets\pub-cert.pem
cd ../../..

tương ứng với 1 tenants sẽ có 1 .env và 1 secrets.whitelist, phải tự tạo nhé