#!/usr/bin/env bash 
set -e


GetProjectRoot() {
  local current="$PWD"
  local maxDepth=10
  local depth=0

  while [[ -n "$current" && $depth -lt $maxDepth ]]; do
    if [[ -f "$current/.gitignore" ]]; then
      echo "$current"
      return 0
    fi

    local parent
    parent="$(dirname "$current")"

    if [[ "$parent" == "$current" ]]; then
      break
    fi

    current="$parent"
    ((depth++))
  done

  echo "Cannot find project root (looking for .gitignore). Make sure you're inside the project directory." >&2
  return 1
}

GetServiceConfig() {
  local ServiceDir="$1"
  local serviceFile="$ServiceDir/service.yaml"

  if [[ ! -f "$serviceFile" ]]; then
    echo "service.yaml not found in $ServiceDir" >&2
    return 1
  fi

  if ! yq '.' "$serviceFile" >/dev/null 2>&1; then
    echo "Failed to parse service.yaml" >&2
    return 1
  fi

  if [[ "$(yq '.service' "$serviceFile")" == "null" ]]; then
    echo "Invalid service.yaml: missing 'service' section" >&2
    return 1
  fi

  echo "$serviceFile"
}

TestDependencies() {
  local missing=()

  if ! command -v yq >/dev/null 2>&1; then
    missing+=("yq\n  Install: https://github.com/mikefarah/yq")
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    missing+=("kubectl\n  Install: https://kubernetes.io/docs/tasks/tools/")
  fi

  if ! command -v kubeseal >/dev/null 2>&1; then
    missing+=("kubeseal\n  Install: https://github.com/bitnami-labs/sealed-secrets#kubeseal")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "Missing required dependencies:\n" >&2
    for item in "${missing[@]}"; do
      echo -e "  • $item" >&2
    done
    return 1
  fi
}

WriteColorOutput() {
  local Message="$1"
  local Type="${2:-Info}"

  case "$Type" in
    Success) echo -e "\033[32m[+] $Message\033[0m" ;;
    Error)   echo -e "\033[31m[X] $Message\033[0m" ;;
    Warning) echo -e "\033[33m[!] $Message\033[0m" ;;
    Step)    echo -e "\n\033[36m[>] $Message\033[0m" ;;
    Info)    echo -e "\033[90m  $Message\033[0m" ;;
    *) echo "$Message" ;;
  esac
}

InvokeWithErrorHandling() {
  local ErrorMessage="$1"
  shift

  "$@"
  local exitCode=$?

  if [[ $exitCode -ne 0 ]]; then
    echo "$ErrorMessage (exit code: $exitCode)" >&2
    return 1
  fi
}
