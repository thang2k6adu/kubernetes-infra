#!/usr/bin/env bash
set -euo pipefail

# Seal imagePullSecret cho mọi tenant có dùng registry private.
# Dùng cho cả backfill lần đầu lẫn xoay mật khẩu registry về sau.
#
#   ./scripts/seal-registry-creds.sh --ClusterName cluster-prod
#
# Credential lấy từ REGISTRY_SERVER/REGISTRY_USER/REGISTRY_PASSWORD nếu đã
# export, không thì hỏi. Mật khẩu được ghi vào .env của từng service (đã
# gitignore) để lần chạy seal-env.sh sau tự sinh lại được file sealed.

scriptRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rootDir="$(cd "$scriptRoot/.." && pwd)"
source "$scriptRoot/lib/common.sh"

ClusterName=""
CertPath=""
DryRun=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ClusterName) ClusterName="$2"; shift 2 ;;
    --RootDir)     rootDir="$2";     shift 2 ;;
    --CertPath)    CertPath="$2";    shift 2 ;;
    --DryRun)      DryRun=true;      shift ;;
    *) echo "Unknown parameter: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ClusterName" ]]; then
  echo "Cluster name is required. Use --ClusterName parameter." >&2
  exit 1
fi

clusterPath="$rootDir/$ClusterName"
configFile="$clusterPath/cluster-config.yaml"

if [[ ! -f "$configFile" ]]; then
  echo "Cluster configuration file not found: $configFile" >&2
  exit 1
fi

for dep in kubectl kubeseal yq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "Missing dependency: $dep" >&2; exit 1; }
done

servicesPath="$(yq -r '.directoryStructure.servicesPath // "services"' "$configFile")"
tenantsPath="$(yq -r '.directoryStructure.tenantsPath // "tenants"' "$configFile")"
certName="$(yq -r '.directoryStructure.certPath // "pub-cert.pem"' "$configFile")"
[[ -n "$CertPath" ]] || CertPath="$clusterPath/$certName"

if [[ ! -f "$CertPath" ]]; then
  echo "Certificate not found: $CertPath" >&2
  exit 1
fi

: "${REGISTRY_SERVER:=}"
[[ -n "$REGISTRY_SERVER" ]] || read -rp  "Registry server [registry.kruzetech.dev]: " REGISTRY_SERVER
REGISTRY_SERVER="${REGISTRY_SERVER:-registry.kruzetech.dev}"
: "${REGISTRY_USER:=}"
[[ -n "$REGISTRY_USER" ]] || read -rp  "Registry user: " REGISTRY_USER
: "${REGISTRY_PASSWORD:=}"
[[ -n "$REGISTRY_PASSWORD" ]] || { read -rsp "Registry password: " REGISTRY_PASSWORD; echo; }

if [[ -z "$REGISTRY_USER" || -z "$REGISTRY_PASSWORD" ]]; then
  echo "Registry user and password are required." >&2
  exit 1
fi

sealed=(); skipped=()

for tenantDir in "$clusterPath/$tenantsPath"/*/; do
  [[ -d "$tenantDir" ]] || continue
  name="$(basename "$tenantDir")"
  valuesFile="$tenantDir/values.yaml"

  secretName="$(yq -r '.imagePullSecrets[0].name // ""' "$valuesFile" 2>/dev/null || echo "")"
  if [[ -z "$secretName" || "$secretName" == "null" ]]; then
    skipped+=("$name")
    continue
  fi

  if [[ "$DryRun" == true ]]; then
    echo "  [dry-run] $name -> $secretName"
    sealed+=("$name")
    continue
  fi

  kubectl create secret docker-registry "$secretName" \
    --docker-server="$REGISTRY_SERVER" \
    --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASSWORD" \
    -n "$name" \
    --dry-run=client \
    -o yaml \
  | kubeseal --cert "$CertPath" --namespace "$name" --format yaml \
  > "$tenantDir/registry-secret.yaml"

  AddKustomizationResources "$tenantDir/kustomization.yaml" registry-secret.yaml

  envFile="$clusterPath/$servicesPath/$name/.env"
  if [[ -f "$envFile" ]]; then
    tmp="$(mktemp)"
    grep -vE '^\s*REGISTRY_(SERVER|USER|PASSWORD)=' "$envFile" > "$tmp" || true
    {
      echo "REGISTRY_SERVER=$REGISTRY_SERVER"
      echo "REGISTRY_USER=$REGISTRY_USER"
      echo "REGISTRY_PASSWORD=$REGISTRY_PASSWORD"
    } >> "$tmp"
    mv "$tmp" "$envFile"
    chmod 600 "$envFile"
  fi

  echo "  [+] $name"
  sealed+=("$name")
done

unset REGISTRY_PASSWORD

echo ""
echo "Sealed: ${#sealed[@]}"
((${#sealed[@]})) && printf '  * %s\n' "${sealed[@]}"
echo "Skipped (no imagePullSecrets): ${#skipped[@]}"
((${#skipped[@]})) && printf '  - %s\n' "${skipped[@]}"
