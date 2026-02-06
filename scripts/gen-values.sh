#!/usr/bin/env bash

set -e

ClusterName=""
TenantsPath="tenants"  # Default value
RootDir=""
TemplateName="dev"  

while [[ $# -gt 0 ]]; do
  case $1 in
    --ClusterName) ClusterName="$2"; shift 2 ;;
    --TenantsPath) TenantsPath="$2"; shift 2 ;;
    --RootDir) RootDir="$2"; shift 2 ;;
    --ProjectName) ProjectName="$2"; shift 2 ;;
    --TemplateName) TemplateName="$2"; shift 2 ;;
    *) 
      if [[ -z "$ClusterName" ]]; then
        ClusterName="$1"
        shift
      elif [[ "$TenantsPath" == "tenants" ]]; then
        TenantsPath="$1"
        shift
      elif [[ -z "$RootDir" ]]; then
        RootDir="$1"
        shift
      elif [[ "$TemplateName" == "v1" ]]; then
        TemplateName="$1"
        shift
      else
        echo "Unknown parameter: $1"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$ClusterName" && $# -gt 0 ]]; then
  ClusterName="$1"
  shift
fi

if [[ "$TenantsPath" == "tenants" && $# -gt 0 ]]; then
  TenantsPath="$1"
  shift
fi

if [[ -z "$RootDir" && $# -gt 0 ]]; then
  RootDir="$1"
fi

if [[ "$TemplateName" == "v1" && $# -gt 0 ]]; then
  TemplateName="$1"
fi

if [[ -z "$ClusterName" ]]; then
  echo "ClusterName is required"
  exit 1
fi

echo "Using TenantsPath: $TenantsPath"
if [[ -n "$RootDir" ]]; then
  echo "Using RootDir: $RootDir"
fi
echo "Using Template: $TemplateName"

scriptRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scriptRoot/lib/common.sh"

trap 'echo "Failed to copy values.yaml: $ERR"; exit 1' ERR

serviceDir="$(pwd)"

# Check for values.yaml in service directory
if [[ ! -f "$serviceDir/values.yaml" ]]; then
  echo "Error: values.yaml not found in $serviceDir"
  exit 1
fi

echo "Found values.yaml in service directory"

# Get service name from values.yaml
serviceName=$(yq '.nameOverride // ""' "$serviceDir/values.yaml" 2>/dev/null)
if [[ -z "$serviceName" ]]; then
  serviceName=$(yq '.fullnameOverride // ""' "$serviceDir/values.yaml" 2>/dev/null)
fi

if [[ -z "$serviceName" ]]; then
  # Try to get from ProjectName parameter
  if [[ -n "$ProjectName" ]]; then
    serviceName="$ProjectName"
  else
    # Fallback to directory name
    serviceName=$(basename "$serviceDir")
  fi
fi

echo "Service name determined: $serviceName"

if [[ -n "$RootDir" ]]; then
  if [[ ! -d "$RootDir" ]]; then
    echo "Root directory not found: $RootDir"
    exit 1
  fi
  rootDir="$RootDir"
else
  rootDir="$(GetProjectRoot)"
fi

clusterPath="$rootDir/$ClusterName"
if [[ ! -d "$clusterPath" ]]; then
  echo "Cluster directory not found: $clusterPath"
  exit 1
fi

tenantDir="$clusterPath/$TenantsPath/$serviceName"
if [[ ! -d "$tenantDir" ]]; then
  echo "Tenant directory not found: $tenantDir"
  echo "Please run gen-folder.sh first to create the tenant directory"
  exit 1
fi

valuesFile="$tenantDir/values.yaml"

# Copy values.yaml to tenant directory
cp "$serviceDir/values.yaml" "$valuesFile"
echo "[+] Copied values.yaml to tenant directory"

# Validate the copied file
if [[ -f "$valuesFile" ]]; then
  file_size=$(wc -c < "$valuesFile" | awk '{print $1}')
  echo "File size: $file_size bytes"
  echo "Location: $valuesFile"
else
  echo "Error: Failed to copy values.yaml"
  exit 1
fi

exit 0