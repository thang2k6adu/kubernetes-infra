#!/usr/bin/env bash

set -euo pipefail

ClusterName=""
TenantsPath="tenants"  # Default value
RootDir=""
TemplateName="dev"  
TEMPLATE_DIR="${TEMPLATE_DIR:-}"
CLUSTER_ROOT_SEARCH_PATHS="${CLUSTER_ROOT_SEARCH_PATHS:-}"

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

trap 'echo "Failed to generate folder structure"; exit 1' ERR

if [[ -z "$ClusterName" ]]; then
    read -rp "Enter cluster name (ex: cluster-dev): " ClusterName
    [[ -z "$ClusterName" ]] && { echo "Cluster name is required"; exit 1; }
fi

echo "Using TenantsPath: $TenantsPath"
if [[ -n "$RootDir" ]]; then
    echo "Using RootDir: $RootDir"
fi
echo "Using Template: $TemplateName"

baseDir="$(pwd)"
valuesFile="$baseDir/values.yaml"

# Check for values.yaml
if [[ ! -f "$valuesFile" ]]; then
    echo "values.yaml not found in $baseDir"
    exit 1
fi

# Extract service name from values.yaml
# Priority: 1. nameOverride, 2. fullnameOverride, 3. ProjectName parameter, 4. Directory name
serviceName=""

# Try nameOverride first
nameOverride=$(yq '.nameOverride // ""' "$valuesFile" 2>/dev/null)
if [[ -n "$nameOverride" ]]; then
    serviceName="$nameOverride"
    echo "Service name from nameOverride: $serviceName"
fi

# If not found, try fullnameOverride
if [[ -z "$serviceName" ]]; then
    fullnameOverride=$(yq '.fullnameOverride // ""' "$valuesFile" 2>/dev/null)
    if [[ -n "$fullnameOverride" ]]; then
        serviceName="$fullnameOverride"
        echo "Service name from fullnameOverride: $serviceName"
    fi
fi

# If still not found, use ProjectName parameter
if [[ -z "$serviceName" ]]; then
    if [[ -n "$ProjectName" ]]; then
        serviceName="$ProjectName"
        echo "Service name from ProjectName parameter: $serviceName"
    fi
fi

# Last resort: use directory name
if [[ -z "$serviceName" ]]; then
    serviceName=$(basename "$baseDir")
    echo "Service name from directory name: $serviceName"
fi

# Get chart information from values.yaml
# Note: In the new structure, chart info might not be in values.yaml
# We'll try to extract from common locations
chartName=$(yq '.chart.name // ""' "$valuesFile" 2>/dev/null)
chartRepo=$(yq '.chart.repository // ""' "$valuesFile" 2>/dev/null)
releaseName=$(yq '.fullnameOverride // ""' "$valuesFile" 2>/dev/null)

# If releaseName not found, use serviceName
if [[ -z "$releaseName" ]]; then
    releaseName="$serviceName"
fi

# Validation - we need at least serviceName
if [[ -z "$serviceName" ]]; then
    echo "Error: Could not determine service name from values.yaml"
    exit 1
fi

echo ""
echo "Configuration extracted from values.yaml:"
echo "  Service Name: $serviceName"
echo "  Release Name: $releaseName"
echo "  Chart Name: ${chartName:-Not specified in values.yaml}"
echo "  Chart Repo: ${chartRepo:-Not specified in values.yaml}"
echo ""

if [[ -z "$chartName" ]] || [[ -z "$chartRepo" ]]; then
    echo "Note: Chart name and/or repository not found in values.yaml"
    echo "You may need to manually edit kustomization.yaml after generation"
fi

# Find cluster directory
if [[ -n "$RootDir" ]]; then
    if [[ ! -d "$RootDir" ]]; then
        echo "Root directory not found: $RootDir"
        exit 1
    fi
    
    clusterPath="$RootDir/$ClusterName"
    if [[ ! -d "$clusterPath" ]]; then
        echo "Cluster directory not found: $clusterPath"
        exit 1
    fi
else
    # Fallback search logic
    find_cluster_root() {
        local current_dir="$1"
        local cluster_name="$2"
        
        if [[ -n "$CLUSTER_ROOT_SEARCH_PATHS" ]]; then
            IFS=':' read -ra paths <<< "$CLUSTER_ROOT_SEARCH_PATHS"
            for path in "${paths[@]}"; do
                if [[ -d "$path/$cluster_name" ]]; then
                    echo "$path"
                    return 0
                fi
            done
        fi
        
        local search_patterns=(
            "$current_dir/../.."     
            "$current_dir/../../.."
            "$current_dir"          
            "$(dirname "$current_dir")" 
        )
        
        for pattern in "${search_patterns[@]}"; do
            if [[ -d "$pattern/$cluster_name" ]]; then
                echo "$(cd "$pattern" && pwd)"
                return 0
            fi
        done
        
        echo "Cluster not found: $cluster_name (searched from $current_dir)" >&2
        return 1
    }

    rootDir=$(find_cluster_root "$baseDir" "$ClusterName") || exit 1
    clusterPath="$rootDir/$ClusterName"

    if [[ ! -d "$clusterPath" ]]; then
        rootDir="$(cd "$baseDir/../.." && pwd)"
        clusterPath="$rootDir/$ClusterName"
        
        if [[ ! -d "$clusterPath" ]]; then
            echo "Cluster not found: $ClusterName"
            exit 1
        fi
    fi
fi

# Create tenant directory
serviceDir="$clusterPath/$TenantsPath/$serviceName"
mkdir -p "$serviceDir"
echo "Creating tenant directory: $serviceDir"

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find template directory
if [[ -z "$TEMPLATE_DIR" ]]; then
    templatesRoot="$scriptDir/../templates"
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
    echo "Using template from: $templateDir"
else
    templateDir="$TEMPLATE_DIR"
fi

echo "Looking for template files in: $templateDir"

# Find all template files
templateFiles=()
while IFS= read -r -d $'\0' file; do
    templateFiles+=("$(basename "$file")")
done < <(find "$templateDir" -name "*.tpl.yaml" -type f -print0 2>/dev/null)

if [[ ${#templateFiles[@]} -eq 0 ]]; then
    echo "No .tpl.yaml files found in template directory: $templateDir"
    echo "Expected at least: namespace.tpl.yaml and kustomization.tpl.yaml"
    exit 1
fi

echo "Found ${#templateFiles[@]} template files:"
for file in "${templateFiles[@]}"; do
    echo "  - $file"
done

# Define variables for template substitution
declare -A vars
vars[SERVICE_NAME]="$serviceName"
vars[CHART_NAME]="$chartName"
vars[CHART_REPO]="$chartRepo"
vars[RELEASE_NAME]="$releaseName"
vars[TEMPLATE_NAME]="$TemplateName"

# Template processing function
process_template() {
    local template="$1"
    local -n vars_ref="$2"
    
    for key in "${!vars_ref[@]}"; do
        value="${vars_ref[$key]}"
        template="${template//\{\{$key\}\}/$value}"
    done
    
    echo "$template"
}

# Process each template file
for templateFile in "${templateFiles[@]}"; do
    templatePath="$templateDir/$templateFile"
    echo "Processing template: $templateFile"
    
    templateContent=$(cat "$templatePath")
    
    processedContent=$(process_template "$templateContent" vars)
    
    outputFile="${templateFile/.tpl./.}"
    
    echo "$processedContent" > "$serviceDir/$outputFile"
    echo "  -> Created: $outputFile"
done

# Copy values.yaml to tenant directory
if [[ -f "$valuesFile" ]]; then
    cp "$valuesFile" "$serviceDir/values.yaml"
    echo "Copied values.yaml to tenant directory"
fi

# Check for important generated files
importantFiles=("namespace.yaml" "kustomization.yaml")
for importantFile in "${importantFiles[@]}"; do
    if [[ ! -f "$serviceDir/$importantFile" ]]; then
        echo "Warning: Important file not generated: $importantFile"
        echo "Template might be missing: ${importantFile/.yaml/.tpl.yaml}"
    fi
done

echo ""
echo "========================================="
echo "Tenant successfully created at: $serviceDir"
echo "========================================="
echo ""
echo "Generated files:"
ls -la "$serviceDir/"

exit 0