### Steps

1. First access `SETUP_CLUSTER_WITH_GITOPS.md` to setup the cluster with gitops

2. Access `README.md` to understand the architecture, setup argoCD into cluster

3. Access `SETUP_CORE.md` to underestand the core components of the application

4. Access `SERVICES.md` to test all the feature

---

### Cleanup unused resources

Delete unused, err, success pods, non pod replicasSet

```bash
kubectl delete pod -A --field-selector=status.phase=Succeeded
kubectl delete pod -A --field-selector=status.phase=Failed
kubectl get rs -A --no-headers | awk '$4==0 {print $1, $2}' | xargs -r -n2 kubectl delete rs -n
```
