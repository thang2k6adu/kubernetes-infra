# Kubernetes GitOps Repo (kube-prometheus-stack + nginx + k8s dashboard)

> **Note for Testing:** Make sure that your master nodes have at least 3GB RAM. Worker nodes should be at least 2GB RAM for properly working & testing.

This is an example of how I would structure a 1:1 (repo-to-single cluster) setup.

This example assumes (as I mentioned in the 1:1 part above) that it's a single repo for a single cluster. However, this can be modified (quite easily) for poly/mono repos or for multiple clusters. This is meant as a good starting point and not what your final repo will look like.

This is based on Argo CD but the same principals can be applied to Flux.

## Structure

Below is an explanation on how this repo is laid out. You'll notice that I use [Kustomize](https://kustomize.io/) heavily. I do this since I follow the [DRY](https://en.wikipedia.org/wiki/Don%27t_repeat_yourself) principal when it comes to YAML files.

```shell
cluster-XXXX/ # 1
├── bootstrap # 2
│   ├── base
│   │   ├── argocd-ns.yaml
│   │   └── kustomization.yaml
│   └── overlays
│       └── default
│           └── kustomization.yaml
├── components # 3
│   ├── applicationsets
│   │   ├── core-components-appset.yaml
│   │   ├── kustomization.yaml
│   │   └── tenants-appset.yaml
│   └── argocdproj
│       ├── kustomization.yaml
│       └── test-project.yaml
├── core # 4
│   ├── gitops-controller
│   │   └── kustomization.yaml
│   └── sample-admin-config
│       ├── kustomization.yaml
│       └── sample-admin-config.yaml
└── tenants # 5
    ├── bgd-blue
    │   ├── bgd-deployment.yaml
    │   └── kustomization.yaml
    └── myapp
        ├── kustomization.yaml
        ├── myapp-deployment.yaml
        ├── myapp-ns.yaml
        └── myapp-service.yaml
```

### Directory Structure Explanation

| # | Directory Name | Description |
|---|----------------|-------------|
| 1. | `cluster-XXXX` | This is the cluster name. This name should be unique to the specific cluster you're targeting. If you're using CAPI, this should be the name of your cluster, the output of `kubectl get cluster` |
| 2. | `bootstrap` | This is where bootstrapping specific configurations are stored. These are items that get the cluster/automation started. They are usually install manifests.<br /><br />`base` is where are the "common" YAML would live and `overlays` are configurations specific to the cluster.<br /><br />The `kustomization.yaml` file in `default` has `cluster-XXXX/components/applicationsets/` and `cluster-XXXX/components/argocdproj/` as a part of it's `bases` config. |
| 3. | `components` | This is where specific components for the GitOps Controller lives (in this case Argo CD).<br /><br />`applicationsets` is where all the ApplicationSets YAMLs live and `argocdproj` is where the ArgoAppProject YAMLs live.<br /><br />Other things that can live here are RBAC, Git repo, and other Argo CD specific configurations (each in their respective directories). |
| 4. | `core` | This is where YAML for the core functionality of the cluster live. Here is where the Kubernetes administrator will put things that is necessary for the functionality of the cluster (like cluster configs or cluster workloads).<br /><br />Under `gitops-controller` is where you are using Argo CD to manage itself. The `kustomization.yaml` file uses `cluster-XXXX/bootstrap/overlays/default` in it's `bases` configuration. This `core` directory gets deployed as an applicationset which can be found under `cluster-XXXX/components/applicationsets/core-components-appset.yaml`.<br /><br />To add a new "core functionality" workload, one needs to add a directory with some yaml in the `core` directory. See the `sample-admin-config` directory as an example. |
| 5. | `tenants` | This is where the workloads for this cluster live.<br /><br />Similar to `core`, the `tenants` directory gets loaded as part of an ApplicationSet that is under `cluster-XXXX/components/applicationsets/tenants-appset.yaml`.<br /><br />This is where Developers/Release Engineers do the work. They just need to commit a directory with some YAML and the applicationset takes care of creating the workload.<br /><br />**Note** that `bgd-blue/kustomization.yaml` file points to another Git repo. This is to show that you can host your YAML in one repo, or many repos. |

## Testing

### Step 1: Install Argo CD

Install the Argo CD first to apply. Don't worry, after that all resources will be synced with remote repo. Without manual installation, we could not apply repo.

```shell
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml
```

### Step 2: Apply the Repository

Then, just apply this repo:

```shell
kubectl apply -k https://github.com/thang2k6adu/kubernetes-infra/cluster-dev/bootstrap/overlays/default
```

### Step 3: Verify Applications

This should give you 4 applications:

```shell
kubectl get applications -n argocd

NAME                   SYNC STATUS   HEALTH STATUS
gitops-controller      OutOfSync     Progressing
kubernetes-dashboard   Synced        Progressing
monitoring             OutOfSync     Missing
myapp                  Synced        Progressing
nginx-ingress          OutOfSync     Missing
```

Backed by 2 applicationsets:

```shell
kubectl get appsets -n argocd

NAME      AGE
cluster   110s
tenants   110s
```

### Step 4: Access Argo CD UI

To see the Argo CD UI, you'll first need the password:

```shell
kubectl get secret/argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d ; echo
```

Then port-forward to see it in your browser (using `admin` as the username):

```shell
kubectl -n argocd port-forward --address 0.0.0.0 service/argocd-server 8080:443
```

### Additional Firewall Configuration

Check firewall:

```shell
sudo ufw allow 8080
```

Access the UI at: https://192.168.0.50:8080

**Disable after done:**

```shell
sudo ufw delete allow 8080
```
**Mở rộng ổ đĩa (fix err with auto install (just 50% disk)):**

```shell
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

# Creating a New Tenant/Service

## Prerequisites

Before creating a new tenant, ensure your cluster has:

1. cluster-{name}/services/
2. cluster-config.yaml
3. pub-cert.pem

## Step-by-Step Process

### Step 1: Create Service Configuration

Navigate to your cluster's services directory and create a new service folder:

```bash
# Navigate to your cluster directory
cd cluster-dev/services/

# Create a new service directory (e.g., pp191225-api)
mkdir pp191225-api
cd pp191225-api
```

### Step 2: Create Required Files

Create the following three files in your service directory:

**1. `service.yaml`** (copy from example):
```bash
cp ../../../service-example.yaml service.yaml
# Edit service.yaml with your service details
```

**2. `.env`** (environment variables):
```bash
# Create .env file with your environment variables
cat > .env << EOF
DATABASE_URL=postgresql://user:pass@db:5432/mydb
REDIS_HOST=redis-service
LOG_LEVEL=info
API_KEY=supersecretkey
OTHER_CONFIG=value
EOF
```

**3. `secrets.whitelist`** (secrets to encrypt):
```bash
# Create secrets.whitelist file listing variables to encrypt
cat > secrets.whitelist << EOF
DATABASE_URL
API_KEY
EOF
```

### Step 3: Configure Service Details

Edit `service.yaml` to match your service:

```yaml
service:
  name: "pp191225-api"        # Must match directory name
  template: "v1"              # Template version to use
  replicaCount: 2
  image:
    repository: "your-registry/pp191225-api"
    tag: "latest"
  # Add any other service-specific configurations
```

### Step 4: Run Deployment Script

From the repository root, run the deployment script:

```bash
# Interactive mode (follow prompts)
./scripts/deploy-service.sh
```

### Step 5: Verify and Commit
