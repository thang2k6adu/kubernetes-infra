<#
.SYNOPSIS
    Generate Helm values.yaml from service.yaml using template file
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "lib\common.ps1")

try {
    $serviceDir = Get-Location
    $svc = Get-ServiceConfig -ServiceDir $serviceDir

    $name = $svc.service.name
    if (-not $name) {
        throw "service.name is required in service.yaml"
    }

    $rootDir = Get-ProjectRoot
    $clusterPath = Join-Path $rootDir $ClusterName
    if (!(Test-Path $clusterPath)) {
        throw "Cluster directory not found: $clusterPath"
    }

    $tenantDir = Join-Path $clusterPath "tenants\$name"
    if (!(Test-Path $tenantDir)) {
        throw "Tenant directory not found: $tenantDir"
    }

    $valuesFile = Join-Path $tenantDir "values.yaml"

    $templatePath = Join-Path $scriptRoot "templates\values.tpl.yaml"
    if (!(Test-Path $templatePath)) {
        throw "Template not found: $templatePath"
    }

    $template = Get-Content $templatePath -Raw

    function Get-ConfigValue {
        param(
            [string]$Path,
            $Default = $null
        )

        $segments = $Path -split '\.'
        $current = $svc

        foreach ($segment in $segments) {
            if ($null -eq $current) { return $Default }

            if ($current -is [hashtable]) {
                if ($current.ContainsKey($segment)) {
                    $current = $current[$segment]
                } else {
                    return $Default
                }
            }
            else {
                if ($current.PSObject.Properties.Name -contains $segment) {
                    $current = $current.$segment
                } else {
                    return $Default
                }
            }
        }

        return $current
    }

    $baseName = $name -replace '-api$', ''
    $configMapName = "$baseName-config"
    $secretName = "$baseName-secret"

    $vars = @{
        SERVICE_NAME        = $name
        IMAGE_REPO          = Get-ConfigValue "image.repository"
        IMAGE_TAG           = Get-ConfigValue "image.tag"
        IMAGE_PULL_POLICY   = Get-ConfigValue "image.pullPolicy"
        REPLICAS            = Get-ConfigValue "replicas"
        PORT                = Get-ConfigValue "network.port"
        DOMAIN              = Get-ConfigValue "network.domain"

        CPU_REQUEST         = Get-ConfigValue "resources.cpu.request"
        CPU_LIMIT           = Get-ConfigValue "resources.cpu.limit"
        MEM_REQUEST         = Get-ConfigValue "resources.memory.request"
        MEM_LIMIT           = Get-ConfigValue "resources.memory.limit"

        LIVENESS_PATH       = Get-ConfigValue "healthcheck.liveness.path"
        READINESS_PATH      = Get-ConfigValue "healthcheck.readiness.path"
        STARTUP_PATH        = Get-ConfigValue "healthcheck.startup.path"

        AUTOSCALING_ENABLED = (Get-ConfigValue "autoscaling.enabled").ToString().ToLower()
        MIN_REPLICAS        = Get-ConfigValue "autoscaling.min"
        MAX_REPLICAS        = Get-ConfigValue "autoscaling.max"
        CPU_TARGET          = Get-ConfigValue "autoscaling.cpuTarget"
        MEM_TARGET          = Get-ConfigValue "autoscaling.memoryTarget"

        PERSISTENCE_ENABLED = (Get-ConfigValue "persistence.enabled").ToString().ToLower()
        PERSISTENCE_SIZE    = Get-ConfigValue "persistence.size"
        PERSISTENCE_PATH    = Get-ConfigValue "persistence.mountPath"

        CONFIGMAP_NAME      = $configMapName
        SECRET_NAME         = $secretName
    }

    foreach ($key in $vars.Keys) {
        if ($null -eq $vars[$key]) {
            throw "Missing value for {{$key}} in service.yaml"
        }

        $template = $template -replace "{{${key}}}", $vars[$key]
    }

    $template | Out-File $valuesFile -Encoding utf8

    Write-Host "[+] values.yaml generated successfully" -ForegroundColor Green
    Write-Host "File: $valuesFile"
    exit 0
}
catch {
    Write-Error "Failed to generate values.yaml: $($_.Exception.Message)"
    exit 1
}
