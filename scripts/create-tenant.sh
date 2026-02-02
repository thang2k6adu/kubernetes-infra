#!/usr/bin/env bash
set -e

ProjectName=""
ClusterName=""
CertPath=""
TemplateName=""
DryRun=false
VerboseOutput=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --ProjectName) ProjectName="$2"; shift 2 ;;
    --ClusterName) ClusterName="$2"; shift 2 ;;
    --CertPath) CertPath="$2"; shift 2 ;;
    --TemplateName) TemplateName="$2"; shift 2 ;;
    --DryRun) DryRun=true; shift ;;
    --VerboseOutput) VerboseOutput=true; shift ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
done

scriptRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
libPath="$scriptRoot/lib"
templatesDir="$scriptRoot/../templates"

if [[ ! -f "$libPath/common.sh" || ! -f "$libPath/validation.sh" ]]; then
  echo "Required library files not found in $libPath. Please ensure lib/common.sh and lib/validation.sh exist."
  exit 1
fi

source "$libPath/common.sh"
source "$libPath/validation.sh"

trap 'echo "Operation cancelled by user"; exit 130' INT TERM

serviceName=""

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

# Function to list available templates
ListAvailableTemplates() {
  local templatesDir="$1"
  local availableTemplates=()
  
  if [[ ! -d "$templatesDir" ]]; then
    echo "Warning: Templates directory not found: $templatesDir"
    return 1
  fi
  
  # Find all template directories that contain namespace.tpl.yaml
  while IFS= read -r -d $'\0' dir; do
    if [[ -f "$dir/namespace.tpl.yaml" ]]; then
      templateName=$(basename "$dir")
      availableTemplates+=("$templateName")
    fi
  done < <(find "$templatesDir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
  
  if [[ ${#availableTemplates[@]} -eq 0 ]]; then
    echo "No templates found in $templatesDir"
    return 1
  fi
  
  # Sort templates
  IFS=$'\n' sortedTemplates=($(sort <<<"${availableTemplates[*]}"))
  unset IFS
  
  echo "${sortedTemplates[@]}"
  return 0
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

clear
echo "This script will deploy a service configuration to your cluster"
echo "using GitOps pattern with ArgoCD."
echo ""

WriteSection "Step 1/7: Checking Dependencies"

if ! warnings=$(TestDependencies); then
  echo "Dependency check failed"
  exit 1
fi

echo "All required dependencies are installed"
if [[ -n "$warnings" ]]; then
  echo "$warnings"
fi

WriteSection "Step 2/7: Locating Project Root"

rootDir=$(GetProjectRoot) || { echo "Failed to locate project root"; exit 1; }
echo "Project root: $rootDir"

WriteSection "Step 3/7: Cluster Selection"

clustersPath="$rootDir"
availableClusters=()

while IFS= read -r -d $'\0' dir; do
  availableClusters+=("$(basename "$dir")")
done < <(find "$clustersPath" -maxdepth 1 -mindepth 1 -type d -name "cluster-*" -print0 2>/dev/null)

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

clusterPath="$rootDir/$ClusterName"
if [[ ! -d "$clusterPath" ]]; then
  echo "Cluster directory not found: $clusterPath"
  exit 1
fi
echo "Cluster directory validated: $clusterPath"

# Read cluster configuration for directory structure
WriteSection "Reading Cluster Configuration"

configResult=$(ReadClusterConfig "$clusterPath") || exit 1
IFS=':' read -r clusterServicesPath clusterTenantsPath clusterCertPath <<< "$configResult"

# Build full paths
clusterServicesFullPath="$clusterPath/$clusterServicesPath"
clusterTenantsFullPath="$clusterPath/$clusterTenantsPath"
clusterCertFullPath="$clusterPath/$clusterCertPath"

echo "Cluster services path: $clusterServicesFullPath"
echo "Cluster tenants path: $clusterTenantsFullPath"
echo "Cluster certificate path: $clusterCertFullPath"

WriteSection "Step 4/7: Service Selection"

# Path to service configurations within the cluster
availableServices=()

if [[ -d "$clusterServicesFullPath" ]]; then
  while IFS= read -r -d $'\0' dir; do
    availableServices+=("$(basename "$dir")")
  done < <(find "$clusterServicesFullPath" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
fi

if [[ ${#availableServices[@]} -eq 0 ]]; then
  echo "No services found in $clusterServicesFullPath"
  exit 1
fi

echo ""
echo "Available services in cluster $ClusterName:"
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

# Test service configuration directory within cluster
serviceDir="$clusterServicesFullPath/$ProjectName"
if [[ ! -d "$serviceDir" ]] || [[ ! -f "$serviceDir/service.yaml" ]]; then
  echo "Service configuration not found in cluster $ClusterName: $serviceDir"
  echo "Expected to find service.yaml in the directory"
  exit 1
fi

echo "Service configuration directory validated: $serviceDir"

serviceName=$(yq '.service.name' "$serviceDir/service.yaml")

WriteSection "Step 5/7: Template Selection"

# List available templates
if availableTemplates=$(ListAvailableTemplates "$templatesDir"); then
  IFS=' ' read -r -a templateArray <<< "$availableTemplates"
  
  echo ""
  echo "Available templates:"
  for t in "${templateArray[@]}"; do
    echo "  • $t"
  done
  echo ""
  
  if [[ -z "$TemplateName" ]]; then
    # Check if service.yaml has template preference
    serviceTemplate=$(yq '.service.template // ""' "$serviceDir/service.yaml" 2>/dev/null)
    if [[ -n "$serviceTemplate" && " ${templateArray[*]} " =~ " $serviceTemplate " ]]; then
      echo "Service specifies template: $serviceTemplate"
      TemplateName="$serviceTemplate"
    else
      read -rp "Select template [default: v1]: " TemplateName
      TemplateName="${TemplateName:-v1}"
    fi
  fi
  
  # Validate template exists
  if [[ ! -d "$templatesDir/$TemplateName" ]]; then
    echo "Template '$TemplateName' not found, using default 'v1'"
    TemplateName="v1"
  fi
else
  echo "No templates available, using default 'v1'"
  TemplateName="v1"
fi

echo "Using template: $TemplateName"

# Check if template has all required files
requiredTemplateFiles=("namespace.tpl.yaml" "kustomization.tpl.yaml")
for file in "${requiredTemplateFiles[@]}"; do
  if [[ ! -f "$templatesDir/$TemplateName/$file" ]]; then
    echo "Warning: Template '$TemplateName' is missing '$file'"
  fi
done

WriteSection "Step 6/7: Certificate Selection"

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

WriteSection "Step 7/7: Deployment Execution"

# Define tenant directory based on cluster configuration
tenantDir="$clusterTenantsFullPath/$serviceName"

if [[ "$DryRun" == true ]]; then
  echo "======================================="
  echo "  DRY RUN MODE - No changes will be made"
  echo "======================================="
  echo ""
  echo "Would execute the following commands:"
  echo ""
  echo "1. Generate tenant folder:"
  echo "   $scriptRoot/gen-folder.sh --RootDir \"$rootDir\" --ClusterName \"$ClusterName\" --TenantsPath \"$clusterTenantsPath\" --ProjectName \"$ProjectName\" --TemplateName \"$TemplateName\""
  echo ""
  echo "2. Generate Helm values:"
  echo "   $scriptRoot/gen-values.sh --RootDir \"$rootDir\" --ClusterName \"$ClusterName\" --TenantsPath \"$clusterTenantsPath\" --ProjectName \"$ProjectName\" --TemplateName \"$TemplateName\""
  echo ""
  echo "3. Seal secrets:"
  echo "   $scriptRoot/seal-env.sh --CertPath \"$CertPath\" --RootDir \"$rootDir\" --ClusterName \"$ClusterName\" --TenantsPath \"$clusterTenantsPath\" --ProjectName \"$ProjectName\""
  echo ""
  echo "Output directory:"
  echo "   $tenantDir"
  exit 0
fi

originalLocation=$(pwd)
cd "$serviceDir" || { echo "Failed to change to service directory"; exit 1; }

echo "[1/3] Generating tenant folder structure..."
"$scriptRoot/gen-folder.sh" \
  --RootDir "$rootDir" \
  --ClusterName "$ClusterName" \
  --TenantsPath "$clusterTenantsPath" \
  --ProjectName "$ProjectName" \
  --TemplateName "$TemplateName" || { cd "$originalLocation"; exit 1; }
echo "Tenant folder structure created"

echo "[2/3] Generating Helm values from service configuration..."
"$scriptRoot/gen-values.sh" \
  --RootDir "$rootDir" \
  --ClusterName "$ClusterName" \
  --TenantsPath "$clusterTenantsPath" \
  --ProjectName "$ProjectName" \
  --TemplateName "$TemplateName" || { cd "$originalLocation"; exit 1; }
echo "Helm values.yaml created"

echo "[3/3] Sealing environment variables with kubeseal..."
"$scriptRoot/seal-env.sh" \
  --CertPath "$CertPath" \
  --RootDir "$rootDir" \
  --ClusterName "$ClusterName" \
  --ProjectName "$ProjectName" || { cd "$originalLocation"; exit 1; }
echo "Secrets sealed successfully"

cd "$originalLocation"

echo "======================================================="
echo "  [+] Deployment configuration completed successfully!"
echo "======================================================="

echo "Deployment Details:"
echo "  Service:   $serviceName"
echo "  Cluster:   $ClusterName"
echo "  Namespace: $serviceName"
echo "  Template:  $TemplateName"
echo "  Output:    $tenantDir"
echo ""

echo "Generated Files:"
files=("namespace.yaml" "kustomization.yaml" "values.yaml" "configmap.yaml" "sealed-secret.yaml")
for f in "${files[@]}"; do
  if [[ -f "$tenantDir/$f" ]]; then
    if command -v stat >/dev/null 2>&1; then
      if stat --version 2>/dev/null | grep -q GNU; then
        size=$(stat -c%s "$tenantDir/$f" 2>/dev/null || echo "N/A")
      else
        size=$(stat -f%z "$tenantDir/$f" 2>/dev/null || echo "N/A")
      fi
    else
      size=$(wc -c < "$tenantDir/$f" 2>/dev/null | awk '{print $1}')
    fi
    echo "  [+] $f ($size bytes)"
  fi
done

if [[ -d "$templatesDir/$TemplateName" ]]; then
  templateFiles=$(find "$templatesDir/$TemplateName" -name "*.tpl.yaml" -type f | wc -l)
  echo ""
  echo "Template '$TemplateName' provides $templateFiles template files"
fi