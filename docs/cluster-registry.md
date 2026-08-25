# Cluster Registry

The production k3s cluster uses a standalone OCI registry in the dedicated
`registry-system` namespace. It is intentionally not part of the `flyte`
namespace or the `flyte-devbox` Helm release.

## Endpoints

- Public pull endpoint: `https://docker.ops.fzyun.io`
- Cluster NodePort backend: `http://172.19.66.224:30000`
- Joxit UI backend: `http://172.19.66.224:30001`
- Legacy registry, retained for existing images: `http://docker.ops.fzyun.io:5000`

HAProxy on `aiops-haproxy` terminates the public TLS certificate and routes the
`docker.ops.fzyun.io` `/v2` path to the Registry NodePort and all other paths to
the Joxit UI NodePort. Port 5000 is not changed by this deployment.

The UI runs as two stateless `joxit/docker-registry-ui:2.6.0` replicas in
`registry-system`. It is configured for a single Registry with image deletion
disabled. The Registry remains the source of truth and stays read-only outside
the controlled synchronization window.

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
deployment script after changing the list; the sync is idempotent. Synchronization
selects the cluster host platform (`linux/amd64`) so the installed `skopeo` does
not attempt to copy unrelated multi-architecture attestation manifests. Existing
target manifests are skipped by default; set `FORCE_SYNC=1` when an upstream tag
must be deliberately refreshed.

## Verification

```bash
kubectl -n registry-system get deployment,pod,service,pvc -o wide
curl -fsS https://docker.ops.fzyun.io/ | grep -i '<html'
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

The Joxit UI has no persistent data. To roll it back independently, restore the
HAProxy backup and scale `registry-system/registry-ui` to zero. The Registry API
and PVC are unaffected.
