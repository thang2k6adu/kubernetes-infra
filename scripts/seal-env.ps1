param(
  [string]$Namespace,
  [string]$ConfigMapName,
  [string]$SecretName,
  [string]$CertPath
)

$TenantDir = $PWD.Path
$EnvFile = Join-Path $TenantDir ".env"
$WhitelistFile = Join-Path $TenantDir "secrets.whitelist"
$KustomizationFile = Join-Path $TenantDir "kustomization.yaml"

if (!(Test-Path $EnvFile)) { Write-Error ".env not found"; exit 1 }
if (!(Test-Path $WhitelistFile)) { Write-Error "secrets.whitelist not found"; exit 1 }
if (!(Test-Path $KustomizationFile)) { Write-Error "kustomization.yaml not found"; exit 1 }

$CertPath = Resolve-Path $CertPath

$envLines = Get-Content $EnvFile | Where-Object { $_ -and -not $_.StartsWith("#") }
$whitelist = Get-Content $WhitelistFile

$secretData = @()
$configData = @()

foreach ($line in $envLines) {
  $key, $value = $line -split "=", 2
  if ($whitelist -contains $key) {
    $secretData += "$key=$value"
  } else {
    $configData += "$key=$value"
  }
}

$configData | Out-File config.env -Encoding utf8
$secretData | Out-File secret.env -Encoding utf8

# Tạo ConfigMap với tên truyền vào
kubectl create configmap $ConfigMapName --from-env-file=config.env -n $Namespace --dry-run=client -o yaml > configmap.yaml

# Tạo Secret với tên truyền vào
kubectl create secret generic $SecretName --from-env-file=secret.env -n $Namespace --dry-run=client -o yaml > secret.yaml

# Seal secret
Get-Content secret.yaml | kubeseal --cert $CertPath --namespace $Namespace --format yaml > sealed-secret.yaml

Remove-Item config.env, secret.env, secret.yaml -Force -ErrorAction SilentlyContinue

# ===== Update kustomization.yaml correctly =====
$lines = Get-Content $KustomizationFile

$hasConfig = $lines -match 'configmap.yaml'
$hasSealed = $lines -match 'sealed-secret.yaml'
$resourcesIndex = ($lines | Select-String '^resources:' | Select-Object -First 1).LineNumber

if (-not $resourcesIndex) {
  $lines += "resources:"
  $lines += "  - configmap.yaml"
  $lines += "  - sealed-secret.yaml"
}
else {
  $insertAt = $resourcesIndex
  if (-not $hasConfig) {
    $lines = $lines[0..$insertAt] + "  - configmap.yaml" + $lines[($insertAt+1)..($lines.Length-1)]
    $insertAt++
  }
  if (-not $hasSealed) {
    $lines = $lines[0..$insertAt] + "  - sealed-secret.yaml" + $lines[($insertAt+1)..($lines.Length-1)]
  }
}

$lines | Set-Content $KustomizationFile -Encoding utf8

Write-Host "Done. Generated configmap.yaml and sealed-secret.yaml"
Write-Host "ConfigMap name: $ConfigMapName"
Write-Host "Secret name: $SecretName"
