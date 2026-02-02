[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$CertPath,
    
    [Parameter(Mandatory=$true)]
    [string]$ClusterName
)

$ErrorActionPreference = "Stop"

# Import common functions
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "lib\common.ps1")

try {
    $serviceDir = Get-Location
    
    $envFile = Join-Path $serviceDir ".env"
    $whitelistFile = Join-Path $serviceDir "secrets.whitelist"
    
    if (!(Test-Path $envFile)) {
        throw ".env file not found in $serviceDir`n`nPlease create a .env file with your environment variables."
    }
    
    if (!(Test-Path $whitelistFile)) {
        throw "secrets.whitelist file not found in $serviceDir`n`nPlease create a secrets.whitelist file listing variables that should be sealed as secrets."
    }
    
    if (!(Test-Path $CertPath)) {
        throw "Certificate file not found: $CertPath`n`nPlease provide a valid kubeseal certificate (.pem file)."
    }
    $CertPath = Resolve-Path $CertPath
    Write-Verbose "Using certificate: $CertPath"
    
    # Parse service configuration
    $svc = Get-ServiceConfig -ServiceDir $serviceDir
    $serviceName = $svc.service.name
    $namespace = $serviceName
    
    if (!$serviceName) {
        throw "service.name is required in service.yaml"
    }
    
    # Generate resource names
    $baseName = $serviceName -replace '-api$', ''
    $configMapName = "$baseName-config"
    $secretName = "$baseName-secret"
    
    Write-Host "Processing environment variables:" -ForegroundColor Cyan
    Write-Host "  Service:    $serviceName" -ForegroundColor Gray
    Write-Host "  Namespace:  $namespace" -ForegroundColor Gray
    Write-Host "  ConfigMap:  $configMapName" -ForegroundColor Gray
    Write-Host "  Secret:     $secretName" -ForegroundColor Gray
    Write-Host ""
    
    # Get project root and tenant directory
    $rootDir = Get-ProjectRoot
    $clusterPath = Join-Path $rootDir $ClusterName
    $tenantDir = Join-Path $clusterPath "tenants\$serviceName"
    
    if (!(Test-Path $tenantDir)) {
        throw "Tenant directory not found: $tenantDir`n`nPlease run gen-folder.ps1 first to create the tenant structure."
    }
    
    $originalLocation = Get-Location
    
    try {
        Set-Location $tenantDir
        Write-Verbose "Working directory: $tenantDir"
        
        # Read and parse environment file
        Write-Verbose "Reading .env file"
        $envLines = Get-Content $envFile -ErrorAction Stop | 
            Where-Object { $_ -and !$_.StartsWith("#") -and $_.Trim() -ne "" }
        
        # Read whitelist
        Write-Verbose "Reading secrets.whitelist"
        $whitelist = Get-Content $whitelistFile -ErrorAction Stop | 
            Where-Object { $_ -and !$_.StartsWith("#") -and $_.Trim() -ne "" } |
            ForEach-Object { $_.Trim() }
        
        # Separate variables into secrets and config
        $secretData = @()
        $configData = @()
        $varCount = 0
        
        foreach ($line in $envLines) {
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2]
                $varCount++
                
                if ($whitelist -contains $key) {
                    $secretData += "$key=$value"
                    Write-Verbose "  Secret: $key"
                }
                else {
                    $configData += "$key=$value"
                    Write-Verbose "  Config: $key"
                }
            }
            else {
                Write-Warning "Skipping invalid line in .env: $line"
            }
        }
        
        Write-Host "  Variables:  $varCount total" -ForegroundColor Gray
        Write-Host "    Config:   $($configData.Count)" -ForegroundColor Gray
        Write-Host "    Secrets:  $($secretData.Count)" -ForegroundColor Gray
        Write-Host ""
        
        # Create temporary env files
        Write-Verbose "Creating temporary env files"
        $configData | Set-Content "config.env" -Encoding utf8
        $secretData | Set-Content "secret.env" -Encoding utf8

        
        # Generate ConfigMap
        Write-Host "Creating ConfigMap..." -ForegroundColor Cyan
        $configMapArgs = @(
            "create", "configmap", $configMapName,
            "--from-env-file=config.env",
            "-n", $namespace,
            "--dry-run=client",
            "-o", "yaml"
        )
        
        $configMapYaml = kubectl @configMapArgs 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create ConfigMap: $configMapYaml"
        }
        
        $configMapYaml | Out-File "configmap.yaml" -Encoding utf8
        Write-Host "  [+] configmap.yaml created" -ForegroundColor Green
        
        # Generate Secret
        Write-Host "Creating Secret..." -ForegroundColor Cyan
        $secretArgs = @(
            "create", "secret", "generic", $secretName,
            "--from-env-file=secret.env",
            "-n", $namespace,
            "--dry-run=client",
            "-o", "yaml"
        )
        
        $secretYaml = kubectl @secretArgs 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Secret: $secretYaml"
        }
        
        $secretYaml | Out-File "secret.yaml" -Encoding utf8
        Write-Host "  [+] secret.yaml created" -ForegroundColor Green
        
        # Seal the Secret
        Write-Host "Sealing Secret with kubeseal..." -ForegroundColor Cyan
        $sealArgs = @(
            "--cert", $CertPath,
            "--namespace", $namespace,
            "--format", "yaml"
        )
        
        Get-Content "secret.yaml" | kubeseal @sealArgs | Out-File "sealed-secret.yaml" -Encoding utf8
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to seal secret with kubeseal"
        }
        
        Write-Host "  [+] sealed-secret.yaml created" -ForegroundColor Green
        
        # Clean up temporary files
        Write-Verbose "Cleaning up temporary files"
        Remove-Item "config.env", "secret.env", "secret.yaml" -Force -ErrorAction SilentlyContinue
        
        # Update kustomization.yaml
        Write-Host "Updating kustomization.yaml..." -ForegroundColor Cyan
        $kustomizationFile = "kustomization.yaml"
        
        if (!(Test-Path $kustomizationFile)) {
            throw "kustomization.yaml not found in $tenantDir`n`nPlease run gen-folder.ps1 first."
        }
        
        $lines = @(Get-Content $kustomizationFile)
        
        # Check if resources are already added
        $hasConfigMap = $lines | Where-Object { $_ -match '^\s*-\s*configmap\.yaml' }
        $hasSealedSecret = $lines | Where-Object { $_ -match '^\s*-\s*sealed-secret\.yaml' }
        
        # Find resources section
        $resourcesLine = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^resources:') {
                $resourcesLine = $i
                break
            }
        }
        
        # Build updated content
        $updatedLines = [System.Collections.ArrayList]::new()
        
        if ($null -eq $resourcesLine) {
            # No resources section - add it at the end
            Write-Verbose "Adding resources section to kustomization.yaml"
            $updatedLines.AddRange($lines)
            $updatedLines.Add("") | Out-Null
            $updatedLines.Add("resources:") | Out-Null
            $updatedLines.Add("  - configmap.yaml") | Out-Null
            $updatedLines.Add("  - sealed-secret.yaml") | Out-Null
        }
        else {
            # Resources section exists - add if not present
            $insertIndex = $resourcesLine + 1
            
            # Copy lines up to and including resources:
            for ($i = 0; $i -le $resourcesLine; $i++) {
                $updatedLines.Add($lines[$i]) | Out-Null
            }
            
            # Add configmap if not present
            if (!$hasConfigMap) {
                Write-Verbose "Adding configmap.yaml to resources"
                $updatedLines.Add("  - configmap.yaml") | Out-Null
            }
            
            # Add sealed-secret if not present
            if (!$hasSealedSecret) {
                Write-Verbose "Adding sealed-secret.yaml to resources"
                $updatedLines.Add("  - sealed-secret.yaml") | Out-Null
            }
            
            # Copy remaining existing resource entries and other sections
            for ($i = $resourcesLine + 1; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                
                # Skip if it's one of our resources (in case they were there but we didn't detect them)
                if ($line -match 'configmap\.yaml' -or $line -match 'sealed-secret\.yaml') {
                    continue
                }
                
                $updatedLines.Add($line) | Out-Null
            }
        }
        
        # Write updated kustomization.yaml
        $updatedLines | Set-Content $kustomizationFile -Encoding utf8
        Write-Host "  [+] kustomization.yaml updated" -ForegroundColor Green
        Write-Host ""
        
        # Success summary
        Write-Host "[+] Environment variables sealed successfully!" -ForegroundColor Green
        Write-Host ""
        Write-Host "Generated files in $tenantDir`:" -ForegroundColor Cyan
        Write-Host "  * configmap.yaml     ($($configData.Count) variables)" -ForegroundColor Gray
        Write-Host "  * sealed-secret.yaml ($($secretData.Count) variables)" -ForegroundColor Gray
        Write-Host ""
        
        # Security reminder
        if ($secretData.Count -gt 0) {
            Write-Host "Security Notes:" -ForegroundColor Yellow
            Write-Host "  * Secret values are encrypted with kubeseal" -ForegroundColor Gray
            Write-Host "  * Only the target cluster can decrypt them" -ForegroundColor Gray
            Write-Host "  * Safe to commit sealed-secret.yaml to Git" -ForegroundColor Gray
            Write-Host "  * Never commit the original .env file" -ForegroundColor Gray
            Write-Host ""
        }
        
    }
    finally {
        # Always return to original location
        Set-Location $originalLocation
    }
    
    # Explicit success exit
    exit 0
}
catch {
    Write-Error "Failed to seal environment variables: $($_.Exception.Message)"
    
    # Clean up temporary files on error
    if (Test-Path "config.env") { Remove-Item "config.env" -Force -ErrorAction SilentlyContinue }
    if (Test-Path "secret.env") { Remove-Item "secret.env" -Force -ErrorAction SilentlyContinue }
    if (Test-Path "secret.yaml") { Remove-Item "secret.yaml" -Force -ErrorAction SilentlyContinue }
    
    exit 1
}