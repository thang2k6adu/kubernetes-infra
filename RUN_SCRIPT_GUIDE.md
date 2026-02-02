# Deployment Script Guide

## Prerequisites

### **Common Tools (All Platforms):**
```bash
# 1. Bash Shell
# 2. Git
# 3. yq (YAML processor)
# 4. kubeseal
```

---

## Installation Guide (use bash )

### **Windows**
```powershell
# 1. Install Git Bash or WSL2
#    Download: https://gitforwindows.org/

# 2. Install yq (using scoop)
scoop install yq

# 3. Install kubeseal (using choco)
choco install kubernetes-sealed-secrets
```

### **🐧 Linux (Ubuntu/Debian)**
```bash
# 1. Install dependencies
sudo apt update
sudo apt install -y git curl

# 2. Install yq
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq

# 3. Install kubeseal
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
tar -xvzf kubeseal-0.24.0-linux-amd64.tar.gz
sudo mv kubeseal /usr/local/bin/
```

### **macOS**
```bash
# 1. Install Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Install tools
brew install yq
brew install kubeseal
brew install git
```

---

## 🏃‍♂️ Quick Start

### **1. Clone Repository**
```bash
git clone <your-repo-url>
cd <repo-name>
```

### **2. Verify Project Structure**
```bash

# ├── templates/
# └── scripts/
```

### **3. Basic Usage**
```bash
./scripts/create-tenants.sh

# Or with parameters
./scripts/create-tenant.sh \
  --ClusterName "cluster-prod" \
  --ProjectName "api-service" \
  --TemplateName "v1"
```

---

## Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `--ClusterName` | Target cluster name | `cluster-prod` |
| `--ProjectName` | Service name | `user-service` |
| `--TemplateName` | Template version | `v1` |
| `--CertPath` | kubeseal certificate | `/path/to/cert.pem` |
| `--DryRun` | Preview only | (flag) |
| `--VerboseOutput` | Detailed logs | (flag) |

---

## Workflow

### **Step-by-Step Execution:**
```
1. Dependency Check → 2. Project Root → 3. Cluster Select
       ↓                    ↓                  ↓
4. Service Select → 5. Template Select → 6. Certificate Select
       ↓
7. Deployment Execution
       ↓
   • gen-folder.sh
   • gen-values.sh
   • seal-env.sh
```

## Dry Run Mode

```bash
# Preview changes without applying
./scripts/deploy-service.sh \
  --ClusterName "cluster-dev" \
  --ProjectName "test-service" \
  --DryRun
```