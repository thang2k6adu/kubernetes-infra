#!/usr/bin/env bash

set -e

ClusterName="$1"

if [[ -z "$ClusterName" ]]; then
  echo "ClusterName is required"
  exit 1
fi

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

rootDir="$(GetProjectRoot)"
clusterPath="$rootDir/$ClusterName"
if [[ ! -d "$clusterPath" ]]; then
  echo "Cluster directory not found: $clusterPath"
  exit 1
fi

tenantDir="$clusterPath/tenants/$name"
if [[ ! -d "$tenantDir" ]]; then
  echo "Tenant directory not found: $tenantDir"
  exit 1
fi

valuesFile="$tenantDir/values.yaml"

templatePath="$scriptRoot/templates/values.tpl.yaml"
if [[ ! -f "$templatePath" ]]; then
  echo "Template not found: $templatePath"
  exit 1
fi

serviceYaml="$serviceDir/service.yaml"
if [[ ! -f "$serviceYaml" ]]; then
  echo "service.yaml not found in $serviceDir"
  exit 1
fi

serviceYaml="$(realpath "$serviceYaml")"

# Require gomplate (giữ nguyên kiểm tra 2 lần như PowerShell)
if ! command -v gomplate >/dev/null 2>&1; then
  echo "gomplate is not installed. Install from https://github.com/hairyhenderson/gomplate"
  exit 1
fi

if ! command -v gomplate >/dev/null 2>&1; then
  echo "gomplate is not installed. Install from https://github.com/hairyhenderson/gomplate"
  exit 1
fi

echo "SERVICE YAML = $serviceYaml"
cat "$serviceYaml"

echo "SERVICE YAML = $serviceYaml"
cat "$serviceYaml"

serviceYaml="$(realpath "$serviceYaml")"

json="$(yq -o=json "$serviceYaml")"

echo "$json" | gomplate \
  -c ".=stdin:?type=application/json" \
  -f "$templatePath" \
  -o "$valuesFile"

echo "[+] values.yaml generated successfully"
echo "File: $valuesFile"

echo "[+] values.yaml generated successfully"
echo "[+] values.yaml generated successfully"
echo "File: $valuesFile"

exit 0
