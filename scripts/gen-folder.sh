#!/usr/bin/env bash

set -e

ClusterName="$1"

trap 'echo "Failed to generate folder structure: $ERR"; exit 1' ERR

if [[ -z "$ClusterName" ]]; then
  read -rp "Enter cluster name (ex: cluster-dev): " ClusterName
fi

baseDir="$(pwd)"

serviceFile="$baseDir/service.yaml"
if [[ ! -f "$serviceFile" ]]; then
  echo "service.yaml not found in $baseDir"
  exit 1
fi

# Read yaml values using yq
name=$(yq '.service.name' "$serviceFile")
releaseName=$(yq '.service.releaseName' "$serviceFile")
chartRepo=$(yq '.service.chartRepo' "$serviceFile")
chartName=$(yq '.service.chartName' "$serviceFile")

if [[ -z "$name" || "$name" == "null" ]]; then echo "Missing service.name"; exit 1; fi
if [[ -z "$releaseName" || "$releaseName" == "null" ]]; then echo "Missing service.releaseName"; exit 1; fi
if [[ -z "$chartRepo" || "$chartRepo" == "null" ]]; then echo "Missing service.chartRepo"; exit 1; fi
if [[ -z "$chartName" || "$chartName" == "null" ]]; then echo "Missing service.chartName"; exit 1; fi

# rootDir = go up from services/<project> to repo root
rootDir="$(cd "$baseDir/../.." && pwd)"
clusterPath="$rootDir/$ClusterName"

if [[ ! -d "$clusterPath" ]]; then
  echo "Cluster not found: $ClusterName"
  exit 1
fi

serviceDir="$clusterPath/tenants/$name"
mkdir -p "$serviceDir"

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templateDir="$scriptDir/templates"

if [[ ! -d "$templateDir" ]]; then
  echo "templates folder not found: $templateDir"
  exit 1
fi

namespaceTplPath="$templateDir/namespace.tpl.yaml"
kustomizeTplPath="$templateDir/kustomization.tpl.yaml"

if [[ ! -f "$namespaceTplPath" ]]; then
  echo "Missing template file: namespace.tpl.yaml"
  exit 1
fi

if [[ ! -f "$kustomizeTplPath" ]]; then
  echo "Missing template file: kustomization.tpl.yaml"
  exit 1
fi

namespaceTpl="$(cat "$namespaceTplPath")"
kustomizeTpl="$(cat "$kustomizeTplPath")"

declare -A vars
vars[SERVICE_NAME]="$name"
vars[CHART_NAME]="$chartName"
vars[CHART_REPO]="$chartRepo"
vars[RELEASE_NAME]="$releaseName"

for key in "${!vars[@]}"; do
  value="${vars[$key]}"
  namespaceTpl="${namespaceTpl//\{\{$key\}\}/$value}"
  kustomizeTpl="${kustomizeTpl//\{\{$key\}\}/$value}"
done

echo "$namespaceTpl" > "$serviceDir/namespace.yaml"
echo "$kustomizeTpl" > "$serviceDir/kustomization.yaml"

echo "Tenant created at: $serviceDir"

exit 0
