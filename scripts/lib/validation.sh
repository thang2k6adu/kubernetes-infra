#!/usr/bin/env bash

TestDependencies() {
  local missing=()
  local warnings=()

  local deps=("kubectl" "kubeseal" "gomplate" "yq")

  for d in "${deps[@]}"; do
    if ! command -v "$d" >/dev/null 2>&1; then
      missing+=("$d")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required dependencies:" >&2
    for m in "${missing[@]}"; do
      echo "  • $m" >&2
    done
    return 1
  fi

  return 0
}

TestServiceDirectory() {
  local ProjectName="$1"
  local RootDir="$2"

  local serviceDir="$RootDir/services/$ProjectName"

  if [[ ! -d "$serviceDir" ]]; then
    local available
    available=$(ls -d "$RootDir/services"/* 2>/dev/null | xargs -n1 basename)

    local errorMsg="Service directory not found: $serviceDir"
    if [[ -n "$available" ]]; then
      errorMsg+="\n\nAvailable services:\n"
      for s in $available; do
        errorMsg+="  • $s\n"
      done
    fi
    echo -e "$errorMsg" >&2
    exit 1
  fi

  declare -A requiredFiles=(
    ["service.yaml"]="Service configuration file"
    [".env"]="Environment variables file"
    ["secrets.whitelist"]="Secret variables whitelist file"
  )

  local missing=()

  for file in "${!requiredFiles[@]}"; do
    if [[ ! -f "$serviceDir/$file" ]]; then
      missing+=("$file - ${requiredFiles[$file]}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    local errorMsg="Missing required files in services/$ProjectName:\n\n"
    for m in "${missing[@]}"; do
      errorMsg+="  • $m\n"
    done
    errorMsg+="\nPlease ensure all required files exist before running deployment."
    echo -e "$errorMsg" >&2
    exit 1
  fi

  echo "$serviceDir"
}

TestClusterDirectory() {
  local ClusterName="$1"
  local RootDir="$2"

  local clusterPath="$RootDir/$ClusterName"

  if [[ ! -d "$clusterPath" ]]; then
    local available
    available=$(ls -d "$RootDir"/cluster-* 2>/dev/null | xargs -n1 basename)

    local errorMsg="Cluster directory not found: $clusterPath"
    if [[ -n "$available" ]]; then
      errorMsg+="\n\nAvailable clusters:\n"
      for c in $available; do
        errorMsg+="  • $c\n"
      done
    else
      errorMsg+="\n\nNo cluster directories found. Expected format: cluster-<name>"
    fi
    echo -e "$errorMsg" >&2
    exit 1
  fi

  local expectedDirs=("tenants" "core" "components")
  local hasStructure=false

  for dir in "${expectedDirs[@]}"; do
    if [[ -d "$clusterPath/$dir" ]]; then
      hasStructure=true
      break
    fi
  done

  if [[ "$hasStructure" == false ]]; then
    echo "Warning: Cluster directory exists but doesn't have expected structure (tenants/core/components)" >&2
    echo "This might be OK if it's a new cluster, but verify the path is correct." >&2
  fi

  echo "$clusterPath"
}

GetCertificateFile() {
  local RootDir="$1"
  local Interactive="${2:-true}"

  mapfile -t pemFiles < <(find "$RootDir" -maxdepth 1 -type f -name "*.pem")

  if [[ ${#pemFiles[@]} -eq 0 ]]; then
    echo "No .pem certificate file found in root directory ($RootDir)

Please ensure your kubeseal certificate is in the project root." >&2
    exit 1
  fi

  if [[ ${#pemFiles[@]} -eq 1 ]]; then
    echo "${pemFiles[0]}"
    return
  fi

  if [[ "$Interactive" != true ]]; then
    echo "Multiple certificate files found. Using first one: $(basename "${pemFiles[0]}")" >&2
    echo "${pemFiles[0]}"
    return
  fi

  echo
  echo "Multiple certificate files found:"
  for i in "${!pemFiles[@]}"; do
    local file="${pemFiles[$i]}"
    local size
    size=$(du -k "$file" | awk '{printf "%.2f KB", $1}')
    local modified
    modified=$(date -r "$file" "+%Y-%m-%d %H:%M")
    echo "  [$i] $(basename "$file") - $size - Modified: $modified"
  done
  echo

  local choice valid=false
  while [[ "$valid" == false ]]; do
    read -p "Select certificate [0-$((${#pemFiles[@]} - 1))]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 0 ]] && [[ "$choice" -lt ${#pemFiles[@]} ]]; then
      valid=true
    else
      echo "Invalid selection. Please enter a number between 0 and $((${#pemFiles[@]} - 1))." >&2
    fi
  done

  echo "${pemFiles[$choice]}"
}

TestServiceSchema() {
  local configFile="$1"
  local errors=()

  local requiredFields=(
    ".service.name"
    ".service.releaseName"
    ".service.chartRepo"
    ".image.repository"
    ".image.tag"
    ".image.pullPolicy"
    ".network.port"
    ".resources.cpu.request"
    ".resources.cpu.limit"
    ".resources.memory.request"
    ".resources.memory.limit"
    ".healthcheck.liveness.path"
    ".healthcheck.readiness.path"
    ".healthcheck.startup.path"
  )

  for field in "${requiredFields[@]}"; do
    local value
    value=$(yq "$field" "$configFile")
    if [[ -z "$value" || "$value" == "null" ]]; then
      errors+=("Missing or empty field: ${field#.}")
    fi
  done

  local port
  port=$(yq '.network.port' "$configFile")
  if [[ "$port" != "null" ]]; then
    if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
      errors+=("network.port must be between 1 and 65535 (got: $port)")
    fi
  fi

  local replicas
  replicas=$(yq '.replicas' "$configFile")
  if [[ "$replicas" != "null" && "$replicas" -lt 1 ]]; then
    errors+=("replicas must be at least 1 (got: $replicas)")
  fi

  local min max
  min=$(yq '.autoscaling.min' "$configFile")
  max=$(yq '.autoscaling.max' "$configFile")
  if [[ "$min" != "null" && "$max" != "null" && "$min" -gt "$max" ]]; then
    errors+=("autoscaling.min ($min) cannot be greater than autoscaling.max ($max)")
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    local errorMsg="Invalid service.yaml configuration:\n\n"
    for e in "${errors[@]}"; do
      errorMsg+="  • $e\n"
    done
    echo -e "$errorMsg" >&2
    exit 1
  fi
}

TestEnvironmentFiles() {
  local ServiceDir="$1"

  local envFile="$ServiceDir/.env"
  local whitelistFile="$ServiceDir/secrets.whitelist"

  mapfile -t envLines < <(grep -v '^\s*#' "$envFile" | grep -v '^\s*$')
  mapfile -t whitelist < <(grep -v '^\s*#' "$whitelistFile" | grep -v '^\s*$')

  local envVars=()
  local warnings=()

  for line in "${envLines[@]}"; do
    if [[ "$line" =~ ^([^=]+)= ]]; then
      envVars+=("${BASH_REMATCH[1]}")
    fi
  done

  for var in "${whitelist[@]}"; do
    if [[ ! " ${envVars[*]} " =~ " $var " ]]; then
      warnings+=("Variable '$var' is in secrets.whitelist but not in .env")
    fi
  done

  local duplicates
  duplicates=$(printf "%s\n" "${envVars[@]}" | sort | uniq -d)

  for dup in $duplicates; do
    local count
    count=$(printf "%s\n" "${envVars[@]}" | grep -c "^$dup$")
    warnings+=("Duplicate variable in .env: $dup (appears $count times)")
  done

  local secretCount=0
  for v in "${envVars[@]}"; do
    if [[ " ${whitelist[*]} " =~ " $v " ]]; then
      ((secretCount++))
    fi
  done

  local configCount=$((${#envVars[@]} - secretCount))

  echo "EnvVarCount=${#envVars[@]}"
  echo "SecretVarCount=$secretCount"
  echo "ConfigVarCount=$configCount"
  for w in "${warnings[@]}"; do
    echo "Warning=$w"
  done
}
