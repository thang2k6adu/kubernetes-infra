#!/usr/bin/env bash
set -euo pipefail


CertPath="$1"
ClusterName="$2"

if [[ -z "${CertPath:-}" || -z "${ClusterName:-}" ]]; then
  echo "Usage: $0 <CertPath> <ClusterName>"
  exit 1
fi

scriptRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scriptRoot/lib/common.sh"

serviceDir="$(pwd)"

envFile="$serviceDir/.env"
whitelistFile="$serviceDir/secrets.whitelist"

if [[ ! -f "$envFile" ]]; then
  echo ".env file not found in $serviceDir

Please create a .env file with your environment variables."
  exit 1
fi

if [[ ! -f "$whitelistFile" ]]; then
  echo "secrets.whitelist file not found in $serviceDir

Please create a secrets.whitelist file listing variables that should be sealed as secrets."
  exit 1
fi

if [[ ! -f "$CertPath" ]]; then
  echo "Certificate file not found: $CertPath

Please provide a valid kubeseal certificate (.pem file)."
  exit 1
fi

CertPath="$(realpath "$CertPath")"

serviceName="$(yq '.service.name' service.yaml)"
namespace="$serviceName"

if [[ -z "$serviceName" || "$serviceName" == "null" ]]; then
  echo "service.name is required in service.yaml"
  exit 1
fi

baseName="${serviceName%-api}"
configMapName="${baseName}-config"
secretName="${baseName}-secret"

echo "Processing environment variables:"
echo "  Service:    $serviceName"
echo "  Namespace:  $namespace"
echo "  ConfigMap:  $configMapName"
echo "  Secret:     $secretName"
echo ""

rootDir="$(GetProjectRoot)"
clusterPath="$rootDir/$ClusterName"
tenantDir="$clusterPath/tenants/$serviceName"

if [[ ! -d "$tenantDir" ]]; then
  echo "Tenant directory not found: $tenantDir

Please run gen-folder.ps1 first to create the tenant structure."
  exit 1
fi

originalLocation="$(pwd)"

cleanup() {
  rm -f config.env secret.env secret.yaml 2>/dev/null || true
}
trap cleanup ERR

cd "$tenantDir"

envLines=$(grep -v '^\s*#' "$envFile" | grep -v '^\s*$')
whitelist=$(grep -v '^\s*#' "$whitelistFile" | grep -v '^\s*$' | sed 's/^[ \t]*//;s/[ \t]*$//')

secretData=()
configData=()
varCount=0

while IFS= read -r line; do
  if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
    key="$(echo "${BASH_REMATCH[1]}" | xargs)"
    value="${BASH_REMATCH[2]}"
    ((++varCount))

    if [[ " $whitelist " == *"$key"* ]]; then
  secretData+=("$key=$value")
else
  configData+=("$key=$value")
fi
  else
    echo "Skipping invalid line in .env: $line"
  fi
done <<< "$envLines"

echo "  Variables:  $varCount total"
echo "    Config:   ${#configData[@]}"
echo "    Secrets:  ${#secretData[@]}"
echo ""

printf "%s\n" "${configData[@]}" > config.env
printf "%s\n" "${secretData[@]}" > secret.env

echo "Creating ConfigMap..."
kubectl create configmap "$configMapName" \
  --from-env-file=config.env \
  -n "$namespace" \
  --dry-run=client \
  -o yaml > configmap.yaml

echo "  [+] configmap.yaml created"

echo "Creating Secret..."
kubectl create secret generic "$secretName" \
  --from-env-file=secret.env \
  -n "$namespace" \
  --dry-run=client \
  -o yaml > secret.yaml

echo "  [+] secret.yaml created"

echo "Sealing Secret with kubeseal..."
kubeseal --cert "$CertPath" --namespace "$namespace" --format yaml < secret.yaml > sealed-secret.yaml

echo "  [+] sealed-secret.yaml created"

cleanup

kustomizationFile="kustomization.yaml"

if [[ ! -f "$kustomizationFile" ]]; then
  echo "kustomization.yaml not found in $tenantDir

Please run gen-folder.ps1 first."
  exit 1
fi

mapfile -t lines < "$kustomizationFile"

hasConfigMap=false
hasSealedSecret=false
resourcesLine=-1

for i in "${!lines[@]}"; do
  [[ "${lines[$i]}" =~ ^[[:space:]]*-\s*configmap\.yaml ]] && hasConfigMap=true
  [[ "${lines[$i]}" =~ ^[[:space:]]*-\s*sealed-secret\.yaml ]] && hasSealedSecret=true
  [[ "${lines[$i]}" =~ ^resources: ]] && resourcesLine=$i
done

updatedLines=()

if [[ $resourcesLine -eq -1 ]]; then
  updatedLines=("${lines[@]}")
  updatedLines+=("")
  updatedLines+=("resources:")
  updatedLines+=("  - configmap.yaml")
  updatedLines+=("  - sealed-secret.yaml")
else
  for ((i=0;i<=resourcesLine;i++)); do
    updatedLines+=("${lines[$i]}")
  done

  [[ "$hasConfigMap" == false ]] && updatedLines+=("  - configmap.yaml")
  [[ "$hasSealedSecret" == false ]] && updatedLines+=("  - sealed-secret.yaml")

  for ((i=resourcesLine+1;i<${#lines[@]};i++)); do
    line="${lines[$i]}"
    if [[ "$line" =~ configmap\.yaml || "$line" =~ sealed-secret\.yaml ]]; then
      continue
    fi
    updatedLines+=("$line")
  done
fi

printf "%s\n" "${updatedLines[@]}" > "$kustomizationFile"

echo "  [+] kustomization.yaml updated"
echo ""
echo "[+] Environment variables sealed successfully!"
echo ""
echo "Generated files in $tenantDir:"
echo "  * configmap.yaml     (${#configData[@]} variables)"
echo "  * sealed-secret.yaml (${#secretData[@]} variables)"
echo ""

if [[ ${#secretData[@]} -gt 0 ]]; then
  echo "Security Notes:"
  echo "  * Secret values are encrypted with kubeseal"
  echo "  * Only the target cluster can decrypt them"
  echo "  * Safe to commit sealed-secret.yaml to Git"
  echo "  * Never commit the original .env file"
  echo ""
fi

cd "$originalLocation"
exit 0
