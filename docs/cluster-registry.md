# Cluster Registry

The production k3s cluster uses a standalone OCI registry in the dedicated
`registry-system` namespace. It is intentionally not part of the `flyte`
namespace or the `flyte-devbox` Helm release.

## Endpoints

- Public pull endpoint: `https://docker.ops.fzyun.io`
- Cluster NodePort backend: `http://172.19.66.224:30000`
- Legacy registry, retained for existing images: `http://docker.ops.fzyun.io:5000`

HAProxy on `aiops-haproxy` terminates the public TLS certificate and routes the
`docker.ops.fzyun.io` host on port 443 to the cluster NodePort. Port 5000 is not
changed by this deployment.

## Deployment

All source changes must be committed and pushed to `origin/main` before
deployment. From the Windows checkout, run the orchestrator through WSL:

```powershell
$repoRoot = (git rev-parse --show-toplevel).Trim()
$wslRepoRoot = (wsl.exe -d Ubuntu-22.04 -- wslpath -a $repoRoot).Trim()
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash scripts/deploy-cluster-registry.sh"
```

The script repairs the `aione-gpu2` agent arguments, deploys the Registry,
syncs the curated image list, switches HAProxy, and restarts k3s one node at a
time. The Registry is read-only outside the controlled image-sync window.

The image list is maintained in `deploy/registry/images.txt`. Run the same
deployment script after changing the list; the sync is idempotent.

## Verification

```bash
kubectl -n registry-system get deployment,pod,service,pvc -o wide
curl -fsS https://docker.ops.fzyun.io/v2/
curl -fsS http://docker.ops.fzyun.io:5000/v2/
sudo k3s crictl pull registry.k8s.io/nfd/node-feature-discovery:v0.18.3
```

## Rollback

HAProxy backups are written to `/opt/haproxy/backups/` before every change.
Each node's previous registry configuration is stored under
`/etc/rancher/k3s/registry-backups/`. Restore those files and restart k3s one
node at a time. Scale the `registry-system/registry` Deployment to zero if the
new backend must be disabled; retain the PVC so mirrored images remain
recoverable.
