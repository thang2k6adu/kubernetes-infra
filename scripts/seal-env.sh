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

# Validate service directory - now checking for values.yaml instead of service.yaml
serviceDir="$clusterServicesFullPath/$ProjectName"
if [[ ! -d "$serviceDir" ]]; then
  echo "Service directory not found in cluster $ClusterName: $serviceDir"
  exit 1
fi

# Check for values.yaml (required) and .env/secrets.whitelist (optional)
if [[ ! -f "$serviceDir/values.yaml" ]]; then
  echo "values.yaml not found in service directory: $serviceDir"
  exit 1
fi

echo "Service configuration directory validated: $serviceDir"

# Get service name from values.yaml
# Priority: 1. nameOverride, 2. fullnameOverride, 3. ProjectName parameter
serviceName=""
nameOverride=$(yq '.nameOverride // ""' "$serviceDir/values.yaml" 2>/dev/null)
if [[ -n "$nameOverride" ]]; then
  serviceName="$nameOverride"
fi

if [[ -z "$serviceName" ]]; then
  fullnameOverride=$(yq '.fullnameOverride // ""' "$serviceDir/values.yaml" 2>/dev/null)
  if [[ -n "$fullnameOverride" ]]; then
    serviceName="$fullnameOverride"
  fi
fi

if [[ -z "$serviceName" ]]; then
  # Use ProjectName as fallback
  serviceName="$ProjectName"
fi

namespace="$serviceName"

if [[ -z "$serviceName" ]]; then
  echo "Could not determine service name from values.yaml"
  echo "Please set nameOverride or fullnameOverride in values.yaml"
  exit 1
fi

echo "Service name determined: $serviceName"

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

# Check for environment files
envFile="$serviceDir/.env"
whitelistFile="$serviceDir/secrets.whitelist"

if [[ ! -f "$envFile" ]]; then
  echo "Warning: .env file not found in $serviceDir"
  echo "No environment variables to seal."
  echo "If you need to seal secrets, please create a .env file."
  
  # Create empty configmap.yaml if no .env file
  configMapName="${serviceName}-config"
  
  echo "Creating empty ConfigMap..."
  kubectl create configmap "$configMapName" \
    -n "$namespace" \
    --dry-run=client \
    -o yaml > "$tenantDir/configmap.yaml"
  
  echo "Updating kustomization.yaml..."
  
  kustomizationFile="$tenantDir/kustomization.yaml"
  if [[ -f "$kustomizationFile" ]]; then
    # Remove existing configmap.yaml reference if exists
    tmpFile="$tenantDir/kustomization.tmp"
    grep -v "configmap.yaml" "$kustomizationFile" | grep -v "sealed-secret.yaml" > "$tmpFile"
    # Add configmap.yaml back
    echo "resources:" >> "$tmpFile"
    echo "  - configmap.yaml" >> "$tmpFile"
    mv "$tmpFile" "$kustomizationFile"
  fi
  
  echo "No secrets to seal. Operation completed."
  exit 0
fi

if [[ ! -f "$whitelistFile" ]]; then
  echo "Warning: secrets.whitelist file not found in $serviceDir"
  echo "No secrets will be sealed. If you have secrets to seal, create a secrets.whitelist file."
  echo "All environment variables will be stored in ConfigMap (not encrypted)."
  
  # Process .env file but treat everything as config (not secret)
  envLines=$(grep -v '^\s*#' "$envFile" | grep -v '^\s*$')
  configData=()
  varCount=0
  
  while IFS= read -r line; do
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      key="$(echo "${BASH_REMATCH[1]}" | xargs)"
      value="${BASH_REMATCH[2]}"
      ((++varCount))
      configData+=("$key=$value")
    else
      echo "Skipping invalid line in .env: $line"
    fi
  done <<< "$envLines"
  
  configMapName="${serviceName}-config"
  
  printf "%s\n" "${configData[@]}" > "$tenantDir/config.env"
  
  echo "Creating ConfigMap (${#configData[@]} variables)..."
  kubectl create configmap "$configMapName" \
    --from-env-file="$tenantDir/config.env" \
    -n "$namespace" \
    --dry-run=client \
    -o yaml > "$tenantDir/configmap.yaml"
  
  rm -f "$tenantDir/config.env"
  
  echo "Updating kustomization.yaml..."
  
  kustomizationFile="$tenantDir/kustomization.yaml"
  if [[ -f "$kustomizationFile" ]]; then
    # Remove existing configmap.yaml reference if exists
    tmpFile="$tenantDir/kustomization.tmp"
    grep -v "configmap.yaml" "$kustomizationFile" | grep -v "sealed-secret.yaml" > "$tmpFile"
    # Add configmap.yaml back
    echo "resources:" >> "$tmpFile"
    echo "  - configmap.yaml" >> "$tmpFile"
    mv "$tmpFile" "$kustomizationFile"
  fi
  
  echo "Operation completed. No secrets were sealed."
  exit 0
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
  rm -f "$tenantDir/config.env" "$tenantDir/secret.env" "$tenantDir/secret.yaml" 2>/dev/null || true
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