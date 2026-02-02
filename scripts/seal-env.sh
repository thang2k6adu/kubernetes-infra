#!/usr/bin/env bash
set -euo pipefail

# Parse parameters
CertPath=""
ClusterName=""
RootDir=""
ProjectName=""
VerboseOutput=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --CertPath) CertPath="$2"; shift 2 ;;
    --ClusterName) ClusterName="$2"; shift 2 ;;
    --RootDir) RootDir="$2"; shift 2 ;;
    --ProjectName) ProjectName="$2"; shift 2 ;;
    --VerboseOutput) VerboseOutput=true; shift ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
done

scriptRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
libPath="$scriptRoot/lib"

if [[ ! -f "$libPath/common.sh" ]]; then
  echo "Required library file not found in $libPath. Please ensure lib/common.sh exists."
  exit 1
fi

source "$libPath/common.sh"

trap 'echo "Operation cancelled by user"; exit 130' INT TERM

WriteSection() {
  local Text="$1"
  echo ""
  echo "> $Text"
  printf '%.0s-' {1..60}
  echo ""
}

# Function to read directory structure from cluster-config.yaml
ReadClusterConfig() {
  local clusterPath="$1"
  local configFile="$clusterPath/cluster-config.yaml"
  
  if [[ ! -f "$configFile" ]]; then
    echo "Cluster configuration file not found: $configFile"
    return 1
  fi
  
  # Use yq to extract directory structure
  local servicesPath=$(yq '.directoryStructure.servicesPath // "services"' "$configFile")
  local tenantsPath=$(yq '.directoryStructure.tenantsPath // "tenants"' "$configFile")
  local certPath=$(yq '.directoryStructure.certPath // "pub-cert.pem"' "$configFile")
  
  # Remove quotes if present
  servicesPath="${servicesPath//\"/}"
  tenantsPath="${tenantsPath//\"/}"
  certPath="${certPath//\"/}"
  
  echo "$servicesPath:$tenantsPath:$certPath"
}

WriteSection "Step 1/3: Validating Inputs"

# Get project root
if [[ -n "$RootDir" ]]; then
  if [[ ! -d "$RootDir" ]]; then
    echo "Root directory not found: $RootDir"
    exit 1
  fi
  rootDir="$RootDir"
else
  rootDir="$(GetProjectRoot)" || { echo "Failed to locate project root"; exit 1; }
fi
echo "Project root: $rootDir"

# Validate ClusterName
if [[ -z "$ClusterName" ]]; then
  echo "Cluster name is required. Use --ClusterName parameter."
  exit 1
fi

clusterPath="$rootDir/$ClusterName"
if [[ ! -d "$clusterPath" ]]; then
  echo "Cluster directory not found: $clusterPath"
  exit 1
fi
echo "Cluster directory validated: $clusterPath"

# Read cluster configuration for directory structure
configResult=$(ReadClusterConfig "$clusterPath") || exit 1
IFS=':' read -r clusterServicesPath clusterTenantsPath clusterCertPath <<< "$configResult"

# Build full paths
clusterServicesFullPath="$clusterPath/$clusterServicesPath"
clusterTenantsFullPath="$clusterPath/$clusterTenantsPath"
clusterCertFullPath="$clusterPath/$clusterCertPath"

echo "Cluster services path: $clusterServicesFullPath"
echo "Cluster tenants path: $clusterTenantsFullPath"
echo "Cluster certificate path: $clusterCertFullPath"

# Validate ProjectName
if [[ -z "$ProjectName" ]]; then
  echo "Project name is required. Use --ProjectName parameter."
  exit 1
fi

# Validate service directory
serviceDir="$clusterServicesFullPath/$ProjectName"
if [[ ! -d "$serviceDir" ]] || [[ ! -f "$serviceDir/service.yaml" ]]; then
  echo "Service configuration not found in cluster $ClusterName: $serviceDir"
  echo "Expected to find service.yaml in the directory"
  exit 1
fi

echo "Service configuration directory validated: $serviceDir"

# Get service name from service.yaml
serviceName=$(yq '.service.name' "$serviceDir/service.yaml")
namespace="$serviceName"

if [[ -z "$serviceName" || "$serviceName" == "null" ]]; then
  echo "service.name is required in service.yaml"
  exit 1
fi

# Validate certificate - ƯU TIÊN: từ cluster config trước
if [[ -z "$CertPath" ]]; then
  # Use certificate from cluster config
  if [[ -f "$clusterCertFullPath" ]]; then
    CertPath="$clusterCertFullPath"
  else
    echo "Certificate file not found: $clusterCertFullPath"
    echo "Please check cluster configuration in $clusterPath/cluster-config.yaml"
    echo "or specify certificate with --CertPath parameter."
    exit 1
  fi
else
  [[ -f "$CertPath" ]] || { echo "Certificate file not found: $CertPath"; exit 1; }
fi

CertPath=$(realpath "$CertPath")
echo "Using certificate: $CertPath"

WriteSection "Step 2/3: Validating Environment Files"

tenantDir="$clusterTenantsFullPath/$serviceName"

if [[ ! -d "$tenantDir" ]]; then
  echo "Tenant directory not found: $tenantDir"
  echo "Please run gen-folder.sh first to create the tenant structure."
  exit 1
fi

envFile="$serviceDir/.env"
whitelistFile="$serviceDir/secrets.whitelist"

if [[ ! -f "$envFile" ]]; then
  echo ".env file not found in $serviceDir"
  echo "Please create a .env file with your environment variables."
  exit 1
fi

if [[ ! -f "$whitelistFile" ]]; then
  echo "secrets.whitelist file not found in $serviceDir"
  echo "Please create a secrets.whitelist file listing variables that should be sealed as secrets."
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

WriteSection "Step 3/3: Sealing Environment Variables"

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

# Update kustomization.yaml
kustomizationFile="kustomization.yaml"

if [[ ! -f "$kustomizationFile" ]]; then
  echo "kustomization.yaml not found in $tenantDir"
  echo "Please run gen-folder.sh first."
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