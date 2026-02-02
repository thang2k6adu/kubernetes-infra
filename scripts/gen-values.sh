#!/usr/bin/env bash

set -e

ClusterName=""
TenantsPath="tenants"  # Default value
RootDir=""
TemplateName="v1"  

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

trap 'echo "Failed to generate values.yaml: $ERR"; exit 1' ERR

try() { "$@"; }

serviceDir="$(pwd)"
svc="$(GetServiceConfig "$serviceDir")"

name="$(yq '.service.name' "$serviceDir/service.yaml")"
if [[ -z "$name" || "$name" == "null" ]]; then
  echo "service.name is required in service.yaml"
  exit 1
fi

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

tenantDir="$clusterPath/$TenantsPath/$name"
if [[ ! -d "$tenantDir" ]]; then
  echo "Tenant directory not found: $tenantDir"
  echo "Please run gen-folder.sh first to create the tenant directory"
  exit 1
fi

valuesFile="$tenantDir/values.yaml"

templatesRoot="$scriptRoot/../templates"
if [[ ! -d "$templatesRoot" ]]; then
  echo "Templates root directory not found: $templatesRoot"
  exit 1
fi

if [[ ! -d "$templatesRoot/$TemplateName" ]]; then
  echo "Template '$TemplateName' not found in $templatesRoot"
  echo "Available templates:"
  find "$templatesRoot" -maxdepth 1 -mindepth 1 -type d -exec basename {} \;
  exit 1
fi

templateDir="$templatesRoot/$TemplateName"
templatePath="$templateDir/values.tpl.yaml"

if [[ ! -f "$templatePath" ]]; then
  echo "Warning: values.tpl.yaml not found in $templateDir"
  
  fallbackTemplate="$templatesRoot/values.tpl.yaml"
  if [[ -f "$fallbackTemplate" ]]; then
    templatePath="$fallbackTemplate"
    echo "Using fallback template: $fallbackTemplate"
  else
    echo "No values template found. Creating minimal values.yaml..."
    
    yq '.service' "$serviceDir/service.yaml" > "$valuesFile"
    echo "[+] Minimal values.yaml generated from service.yaml"
    echo "File: $valuesFile"
    exit 0
  fi
fi

serviceYaml="$serviceDir/service.yaml"
if [[ ! -f "$serviceYaml" ]]; then
  echo "service.yaml not found in $serviceDir"
  exit 1
fi

if ! command -v gomplate >/dev/null 2>&1; then
  echo "gomplate is not installed. Install from https://github.com/hairyhenderson/gomplate"
  exit 1
fi

if ! command -v gomplate >/dev/null 2>&1; then
  echo "gomplate is not installed. Install from https://github.com/hairyhenderson/gomplate"
  exit 1
fi

echo "Using template: $templatePath"
echo "Processing service.yaml: $serviceYaml"

serviceYaml="$(realpath "$serviceYaml")"


tempServiceYaml="/tmp/service-with-template-$$.yaml"
cp "$serviceYaml" "$tempServiceYaml"

if ! yq -e '.service.template' "$tempServiceYaml" >/dev/null 2>&1; then
  yq -i '.service.template = "'"$TemplateName"'"' "$tempServiceYaml"
fi

json="$(yq -o=json "$tempServiceYaml")"

echo "$json" | gomplate \
  -c ".=stdin:?type=application/json" \
  -f "$templatePath" \
  -o "$valuesFile"

rm -f "$tempServiceYaml"

echo "[+] values.yaml generated successfully"
echo "File: $valuesFile"

if [[ -f "$valuesFile" ]]; then
  file_size=$(wc -c < "$valuesFile" | awk '{print $1}')
  echo "Generated file size: $file_size bytes"
else
  echo "Warning: values.yaml was not created"
  exit 1
fi

exit 0