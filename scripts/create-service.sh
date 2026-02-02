#!/usr/bin/env bash
set -e

ProjectName=""
ClusterName=""
CertPath=""
DryRun=false
VerboseOutput=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --ProjectName) ProjectName="$2"; shift 2 ;;
    --ClusterName) ClusterName="$2"; shift 2 ;;
    --CertPath) CertPath="$2"; shift 2 ;;
    --DryRun) DryRun=true; shift ;;
    --VerboseOutput) VerboseOutput=true; shift ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
done

scriptRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
libPath="$scriptRoot/lib"

if [[ ! -f "$libPath/common.sh" || ! -f "$libPath/validation.sh" ]]; then
  echo "Required library files not found in $libPath. Please ensure lib/common.sh and lib/validation.sh exist."
  exit 1
fi

source "$libPath/common.sh"
source "$libPath/validation.sh"

WriteBanner() {
  local Text="$1"
  local border=$(printf '=%.0s' {1..60})
  echo ""
  echo "$border"
  echo "  $Text"
  echo "$border"
  echo ""
}

WriteSection() {
  local Text="$1"
  echo ""
  echo "> $Text"
  printf '%.0s-' {1..60}
  echo ""
}

GetUserInput() {
  local Prompt="$1"
  shift
  local Suggestions=("$@")

  if [[ ${#Suggestions[@]} -gt 0 ]]; then
    echo ""
    echo "Available options:"
    for s in "${Suggestions[@]}"; do
      echo "  * $s"
    done
    echo ""
  fi

  while true; do
    read -rp "$Prompt: " input
    if [[ -n "$input" ]]; then
      echo "$input"
      return
    fi
    echo "This field is required. Please enter a value."
  done
}

clear
echo "This script will deploy a service configuration to your cluster"
echo "using GitOps pattern with ArgoCD."
echo ""

WriteSection "Step 1/6: Checking Dependencies"

if ! warnings=$(TestDependencies); then
  echo "Dependency check failed"
  exit 1
fi

echo "All required dependencies are installed"
if [[ -n "$warnings" ]]; then
  echo "$warnings"
fi

WriteSection "Step 2/6: Locating Project Root"

rootDir=$(GetProjectRoot) || { echo "Failed to locate project root"; exit 1; }
echo "Project root: $rootDir"

WriteSection "Step 3/6: Service Selection"

servicesPath="$rootDir/services"
availableServices=()

if [[ -d "$servicesPath" ]]; then
  mapfile -t availableServices < <(ls -d "$servicesPath"/*/ 2>/dev/null | xargs -n1 basename)
fi

if [[ ${#availableServices[@]} -eq 0 ]]; then
  echo "No services found in $servicesPath"
  exit 1
fi

echo ""
echo "Available services:"
for s in "${availableServices[@]}"; do
  echo "  • $s"
done
echo ""

if [[ -z "$ProjectName" ]]; then
  read -rp "Enter service name: " ProjectName
fi

if [[ -z "$ProjectName" ]]; then
  echo "Service name is required"
  exit 1
fi

serviceDir=$(TestServiceDirectory "$ProjectName" "$rootDir") || exit 1
echo "Service directory validated: $serviceDir"

WriteSection "Step 4/6: Cluster Selection"

clustersPath="$rootDir"
availableClusters=()

mapfile -t availableClusters < <(ls -d "$clustersPath"/cluster-* 2>/dev/null | xargs -n1 basename)

if [[ ${#availableClusters[@]} -eq 0 ]]; then
  echo "No clusters found in $clustersPath"
  exit 1
fi

echo ""
echo "Available clusters:"
for c in "${availableClusters[@]}"; do
  echo "  • $c"
done
echo ""

if [[ -z "$ClusterName" ]]; then
  read -rp "Enter cluster name: " ClusterName
fi

if [[ -z "$ClusterName" ]]; then
  echo "Cluster name is required"
  exit 1
fi

clusterPath=$(TestClusterDirectory "$ClusterName" "$rootDir") || exit 1
echo "Cluster directory validated: $clusterPath"


WriteSection "Step 5/6: Certificate Selection"

if [[ -z "$CertPath" ]]; then
  CertPath=$(GetCertificateFile "$rootDir")
else
  [[ -f "$CertPath" ]] || { echo "Certificate file not found: $CertPath"; exit 1; }
  CertPath=$(realpath "$CertPath")
fi

echo "Using certificate: $CertPath"

WriteSection "Step 6/6: Deployment Execution"

if [[ "$DryRun" == true ]]; then
  echo "======================================="
  echo "  DRY RUN MODE - No changes will be made"
  echo "======================================="
  echo ""
  echo "Would execute the following commands:"
  echo ""
  echo "1. Generate tenant folder:"
  echo "   $scriptRoot/gen-folder.sh --ClusterName $ClusterName"
  echo ""
  echo "2. Generate Helm values:"
  echo "   $scriptRoot/gen-values.sh --ClusterName $ClusterName"
  echo ""
  echo "3. Seal secrets:"
  echo "   $scriptRoot/seal-env.sh --CertPath $CertPath --ClusterName $ClusterName"
  echo ""
  echo "Output directory:"
  echo "   $clusterPath/tenants/$(yq '.service.name' "$serviceDir/service.yaml")"
  exit 0
fi

originalLocation=$(pwd)
cd "$serviceDir"

echo "[1/3] Generating tenant folder structure..."
"$scriptRoot/gen-folder.sh" "$ClusterName" || exit 1
echo "Tenant folder structure created"

echo "[2/3] Generating Helm values from service configuration..."
"$scriptRoot/gen-values.sh" "$ClusterName" || exit 1
echo "Helm values.yaml created"

echo "[3/3] Sealing environment variables with kubeseal..."
"$scriptRoot/seal-env.sh" "$CertPath" "$ClusterName" || exit 1
echo "Secrets sealed successfully"

cd "$originalLocation"

tenantDir="$clusterPath/tenants/$(yq '.service.name' "$serviceDir/service.yaml")"

echo "======================================================="
echo "  [+] Deployment configuration completed successfully!"
echo "======================================================="

echo "Deployment Details:"
echo "  Service:   $(yq '.service.name' "$serviceDir/service.yaml")"
echo "  Cluster:   $ClusterName"
echo "  Namespace: $(yq '.service.name' "$serviceDir/service.yaml")"
echo "  Output:    $tenantDir"
echo ""

echo "Generated Files:"
files=("namespace.yaml" "kustomization.yaml" "values.yaml" "configmap.yaml" "sealed-secret.yaml")
for f in "${files[@]}"; do
  if [[ -f "$tenantDir/$f" ]]; then
    size=$(stat -c%s "$tenantDir/$f")
    echo "  [+] $f ($size bytes)"
  fi
done
