param(
    [string]$ClusterName
)

# Stop on any error
$ErrorActionPreference = "Stop"

try {

if (-not $ClusterName -or $ClusterName.Trim() -eq "") {
    $ClusterName = Read-Host "Enter cluster name (ex: cluster-dev)"
}

# baseDir = services/<project>
$baseDir = Get-Location

$serviceFile = Join-Path $baseDir "service.yaml"
if (!(Test-Path $serviceFile)) {
    Write-Error "service.yaml not found in $baseDir"
    exit 1
}

$svc = Get-Content $serviceFile -Raw | ConvertFrom-Yaml

if (-not $svc.service.name) { Write-Error "Missing service.name"; exit 1 }
if (-not $svc.service.releaseName) { Write-Error "Missing service.releaseName"; exit 1 }
if (-not $svc.service.chartRepo) { Write-Error "Missing service.chartRepo"; exit 1 }
if (-not $svc.service.chartName) { Write-Error "Missing service.chartName"; exit 1 }

$name = $svc.service.name
$releaseName = $svc.service.releaseName
$chartRepo = $svc.service.chartRepo
$chartName = $svc.service.chartName

# ===== rootDir = go up from services/<project> to repo root =====
$rootDir = Resolve-Path (Join-Path $baseDir "..\..")
$clusterPath = Join-Path $rootDir $ClusterName

if (!(Test-Path $clusterPath)) {
    Write-Error "Cluster not found: $ClusterName"
    exit 1
}

$serviceDir = Join-Path $clusterPath "tenants\$name"
New-Item -ItemType Directory -Force -Path $serviceDir | Out-Null

# namespace.yaml
@"
apiVersion: v1
kind: Namespace
metadata:
  name: $name
"@ | Set-Content (Join-Path $serviceDir "namespace.yaml") -Encoding utf8

# kustomization.yaml
@"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $name

resources:
  - namespace.yaml

helmCharts:
  - name: $chartName
    repo: $chartRepo
    version: 0.1.0
    releaseName: $releaseName
    namespace: $name
    valuesFile: values.yaml
"@ | Set-Content (Join-Path $serviceDir "kustomization.yaml") -Encoding utf8

Write-Host "Tenant created at: $serviceDir"

# Explicitly exit with success code
exit 0
}
catch {
    Write-Error "Failed to generate folder structure: $($_.Exception.Message)"
    exit 1
}
