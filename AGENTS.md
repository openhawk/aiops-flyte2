# AiOps Flyte 2 Agent Guide

This file is the project-level instruction file for Codex and other coding agents working in this repository.

## Project Layout

Repository root:

```text
D:\code-work\aiops-flyte2
```

Important areas:

```text
flyteplugins/aione/sshworkspace/   # Custom SSH workspace task plugin
executor/                          # Flyte task/plugin execution and plugin registration
charts/flyte-devbox/               # Single-node k3s Helm deployment
deploy/tests/                      # Local scripts that call Flyte 2 APIs
deploy/ui/                         # Kubernetes manifests for source-built console deployment
flyte_console/                     # Flyte 2 Console frontend
docs/                              # Human-facing project documentation
```

Current deployment defaults:

```text
Backend API and original console ingress: http://172.19.66.218:30080
Source-built console NodePort:           http://172.19.66.218:30081/v2/projects
Kubernetes namespace:                    flyte
Remote host:                             aione-flyte2
Remote checkout:                         /opt/aiops-flyte2
Active branch:                           main
```

## Development Environment Boundaries

- Keep the repository and all task-specific Git worktrees on the Windows `D:` drive. The main checkout is `D:\code-work\aiops-flyte2`; create future task worktrees under `D:\code-work\codex-worktree-storage\aiops-flyte2\<task-slug>` on branches named `codex/<task-slug>` and open that exact directory in Codex.
- At the start of a task, resolve the active checkout with `git rev-parse --show-toplevel` and run all repository commands from that checkout. Never switch from a task worktree back to the main checkout just because an example uses the main path.
- Use Windows PowerShell and Windows Git for Codex file operations, Git operations, `pnpm`, Next.js, and Playwright. Frontend dependency installation, tests, local builds, and browser verification must run against a `D:`-drive checkout.
- Do not run `pnpm install`, Next.js builds, or commands that create `node_modules` or `.next` from a checkout under `C:\Users\86176\.codex\worktrees`. Relocate or reopen the task as a `D:`-drive worktree first.
- Do not run `pnpm` from WSL against the same checkout and never share or alternate one `node_modules` tree between Windows and WSL.
- Use WSL distribution `Ubuntu-22.04` for Go commands, Bash scripts, and local deployment orchestration. Convert the active Windows checkout with `wslpath`; examples use `/mnt/d/code-work/aiops-flyte2` for the main checkout.
- Final production frontend and backend images are built only on the remote `aione-flyte2` Linux/containerd environment through the existing deployment scripts. A Windows `pnpm run build:prod` is local verification, not the production image build.

## Development Rules

- Prefer existing repository patterns over new abstractions.
- All source changes must be committed to Git before deployment. Commit messages must clearly describe the functional purpose of the change.
- Remote deployments must obtain repository changes only through `git pull --ff-only` from the active branch. Do not use direct local-to-remote overwrites such as `scp`, `rsync`, zip extraction, or ad hoc file replacement inside the remote checkout.
- Keep generated or local build output out of commits.
- `flyte_console/public/monaco/` is generated during frontend production builds and must not be committed.
- `flyte_console/server.js` at source root is not needed. The runtime `server.js` comes from Next standalone output copied from `.next/standalone`.
- The custom Flyte plugin code belongs under `flyteplugins/aione/`.
- Use the current `git rev-parse --show-toplevel` result for root-level commands unless a command explicitly changes directory.

## Local Verification

Backend/plugin checks use WSL from the active Windows checkout:

```powershell
$repoRoot = (git rev-parse --show-toplevel).Trim()
$wslRepoRoot = (wsl.exe -d Ubuntu-22.04 -- wslpath -a $repoRoot).Trim()

wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && go test ./executor/pkg/plugin/k8s -count=1"
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && go test ./flyteplugins/aione/sshworkspace -count=1"
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash deploy/tests/test_flyte_api_scripts.sh"
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash deploy/tests/test_deploy_aiops_flyte.sh"
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash deploy/tests/test_deploy_flyte_console_source.sh"
```

Frontend local verification uses Windows PowerShell from a `D:`-drive checkout:

```powershell
$repoRoot = (git rev-parse --show-toplevel).Trim()
if ($repoRoot -notmatch '^[dD]:[/\\]') { throw 'Frontend verification requires a D: drive checkout.' }
Set-Location (Join-Path $repoRoot 'flyte_console')

pnpm install --no-frozen-lockfile
pnpm run build:prod
```

`pnpm run build:prod` runs the Next production build and then regenerates Monaco assets through the cross-platform `node ./scripts/copyMonacoAssets.mjs` script. It validates the frontend locally but does not replace the remote Linux/containerd production image build.

Before committing:

```powershell
$repoRoot = (git rev-parse --show-toplevel).Trim()
Set-Location $repoRoot
git status --short
git diff --check
```

## Cluster Registry Image Push And Pull

The standalone cluster Registry runs in the `registry-system` namespace. Its
public OCI endpoint is `https://docker.ops.fzyun.io`; opening the host root in a
browser shows the read-only Joxit UI, while Docker and containerd use the `/v2/`
API on the same host. The legacy Registry at
`http://docker.ops.fzyun.io:5000` remains available for existing images.

Pull an image directly from the new Registry with its mirrored repository path:

```bash
docker pull docker.ops.fzyun.io/nfd/node-feature-discovery:v0.18.3
sudo k3s crictl pull docker.ops.fzyun.io/nfd/node-feature-discovery:v0.18.3
```

All k3s nodes also configure `docker.ops.fzyun.io` as the first mirror for
`docker.io`, `registry.k8s.io`, `quay.io`, and `nvcr.io`. Workloads can therefore
keep their original upstream image reference; for example, this pull tries the
cluster Registry first:

```bash
sudo k3s crictl pull registry.k8s.io/nfd/node-feature-discovery:v0.18.3
```

The Registry has no login requirement, but it is intentionally read-only by
default. The following address and commands are correct only while a controlled
write window is open:

```bash
docker tag my-image:tag docker.ops.fzyun.io/my-project/my-image:tag
docker push docker.ops.fzyun.io/my-project/my-image:tag
```

For upstream or commonly used images, add the fully qualified source image to
`deploy/registry/images.txt`, commit and push the change, then run
`scripts/deploy-cluster-registry.sh`. Its sync flow switches the Registry to
`registry-config-rw`, copies and verifies the images, and restores
`registry-config-ro` even when synchronization fails. Existing destination
manifests are skipped unless `FORCE_SYNC=1` is explicitly set.

Project-built release images use the same controlled write-window model. The
backend deployment script calls `scripts/registry/push-local-images.sh` after
BuildKit finishes, pushes Registry-qualified commit tags through the internal
Registry service, verifies them through the public endpoint, and restores
`registry-config-ro` before Helm deployment begins. The sync and local-push
scripts share a lock so only one write window can run at a time.

For an exceptional direct Docker push, open the write window from a host with
cluster-admin access, wait for the Registry rollout, perform the tag and push,
and immediately restore read-only mode:

```bash
kubectl -n registry-system patch deployment registry --type=strategic \
  -p '{"spec":{"template":{"spec":{"volumes":[{"name":"config","configMap":{"name":"registry-config-rw"}}]}}}}'
kubectl -n registry-system rollout status deployment/registry --timeout=180s

docker tag my-image:tag docker.ops.fzyun.io/my-project/my-image:tag
docker push docker.ops.fzyun.io/my-project/my-image:tag

kubectl -n registry-system patch deployment registry --type=strategic \
  -p '{"spec":{"template":{"spec":{"volumes":[{"name":"config","configMap":{"name":"registry-config-ro"}}]}}}}'
kubectl -n registry-system rollout status deployment/registry --timeout=180s
```

Do not leave this unauthenticated public Registry writable. If routine direct
pushes are required, add authentication and authorization before changing the
default operating mode. Verify the API and catalog after a sync or push:

```bash
curl -fsS https://docker.ops.fzyun.io/v2/
curl -fsS https://docker.ops.fzyun.io/v2/_catalog
```

## Backend Build And Deployment

Remote deployment steps must start from committed code already pushed to `origin/main`; update the remote checkout with `git pull --ff-only` only.

Pull current code on the remote server:

```bash
ssh aione-flyte2
cd /opt/aiops-flyte2
git pull --ff-only origin main
git log -1 --oneline
```

For full backend deployment, including k3s, Helm dependencies, Registry-backed images, PostgreSQL, RustFS, and Flyte binary:

```powershell
$repoRoot = (git rev-parse --show-toplevel).Trim()
$wslRepoRoot = (wsl.exe -d Ubuntu-22.04 -- wslpath -a $repoRoot).Trim()
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash scripts/deploy-aiops-flyte.sh"
```

If the remote server needs a proxy for downloads:

```bash
PROXY_URL=http://172.19.210.24:7897 bash scripts/deploy-aiops-flyte.sh
```

The full deployment script builds and deploys:

```text
Image:     docker.ops.fzyun.io/flyte-binary-v2:main-<commit>
Release:   flyte-devbox
Namespace: flyte
Ingress:   http://172.19.66.218:30080
```

By default, `scripts/deploy-aiops-flyte.sh` generates `IMAGE_TAG=main-$(git rev-parse --short HEAD)`. It builds the backend and downloader with that tag, opens a controlled Registry write window through `scripts/registry/push-local-images.sh`, pushes both images, restores the Registry to read-only mode, and deploys the same immutable tags. It keeps only the latest three backend release images in the build node's k3s containerd. Override `IMAGE_TAG` only for an explicit one-off deployment.

The deployment scripts use nerdctl and BuildKit directly against k3s containerd:

```text
Containerd socket: /run/k3s/containerd/containerd.sock
Containerd ns:     k8s.io
BuildKit service:  buildkit-k3s.service
```

If `/usr/local/bin/nerdctl`, `/usr/local/bin/buildctl`, or `/usr/local/bin/buildkitd` is missing, the deployment scripts install the pinned `nerdctl-full` bundle before building.

For incremental backend-only rebuilds after k3s and Helm are already installed:

```bash
ssh aione-flyte2
cd /opt/aiops-flyte2
git pull --ff-only origin main

COMMIT="$(git rev-parse --short HEAD)"
IMAGE_TAG="main-${COMMIT}"

export BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock
nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io build \
  -f Dockerfile \
  -t "docker.ops.fzyun.io/flyte-binary-v2:${IMAGE_TAG}" \
  .
bash scripts/registry/push-local-images.sh "docker.ops.fzyun.io/flyte-binary-v2:${IMAGE_TAG}"
kubectl -n flyte set image deploy/flyte-binary flyte="docker.ops.fzyun.io/flyte-binary-v2:${IMAGE_TAG}"
kubectl -n flyte rollout status deploy/flyte-binary --timeout=10m
```

The backend and downloader use Registry-qualified immutable tags with `imagePullPolicy: IfNotPresent`, so workloads scheduled on any configured node can pull them from `docker.ops.fzyun.io`. Flyte control-plane pods, PostgreSQL, RustFS, and the source-built frontend remain pinned to `aione-flyte2`; RustFS uses a hostPath on that node, and the source-built frontend still uses its local image with `imagePullPolicy: Never`. Override `CONTROL_PLANE_NODE` only when the stateful data and local images have been migrated to the target node.

If a new pod is stuck before init containers with `FailedCreatePodSandBox` for `rancher/mirrored-pause:3.6`, pull the pause image directly into k3s containerd:

```bash
nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io pull rancher/mirrored-pause:3.6
k3s ctr images ls | grep 'rancher/mirrored-pause.*3.6'
```

Backend verification:

```bash
kubectl -n flyte get pod,svc
curl -I http://172.19.66.218:30080/v2/projects
```

API script checks from the local workspace:

```powershell
$repoRoot = (git rev-parse --show-toplevel).Trim()
$wslRepoRoot = (wsl.exe -d Ubuntu-22.04 -- wslpath -a $repoRoot).Trim()

wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash deploy/tests/start_ml_task.sh"
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash deploy/tests/get_run_status.sh /flytesnacks/development/<run-id>"
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash deploy/tests/start_ssh_workspace.sh"
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash deploy/tests/get_ssh_workspace_connection.sh /flytesnacks/development/<run-id>"
```

## Frontend Build And Deployment

Remote frontend builds must use the committed source already present in `/opt/aiops-flyte2` after `git pull --ff-only`; do not copy local frontend source files directly into the remote checkout.

Frontend Dockerfile:

```text
flyte_console/Dockerfile
```

Base image:

```text
docker.fzyun.io/library/node:23.11.1-alpine3.22
```

The Dockerfile builds from source, runs `pnpm run build:prod`, copies `.next/standalone`, `.next/static`, generated `public`, and `proxy-server.js`, then serves through `node proxy-server.js` on port `8080`.

Deploy the source-built frontend from WSL after committing and pushing. The script coordinates the deployment, while the final image build occurs on the remote Linux/containerd environment:

```powershell
$repoRoot = (git rev-parse --show-toplevel).Trim()
$wslRepoRoot = (wsl.exe -d Ubuntu-22.04 -- wslpath -a $repoRoot).Trim()
wsl.exe -d Ubuntu-22.04 -- bash -lc "cd '$wslRepoRoot' && bash scripts/deploy-flyte-console-source.sh"
```

Create or update the frontend Kubernetes resources:

```bash
kubectl apply -f deploy/ui/flyte-console-extracted.yaml
```

Current frontend Kubernetes deployment:

```text
Deployment:      flyte-console-extracted
Service:         flyte-console-extracted
Image:           flyte-console-extracted:latest
ImagePullPolicy: Never
Container port:  8080
NodePort:        30081
```

Restart and verify:

```bash
kubectl -n flyte rollout restart deploy/flyte-console-extracted
kubectl -n flyte rollout status deploy/flyte-console-extracted --timeout=180s
kubectl -n flyte get pod -l app=flyte-console-extracted -o wide
kubectl -n flyte logs deploy/flyte-console-extracted --tail=80
curl -I http://172.19.66.218:30081/v2/projects
```

Expected HTTP result:

```text
HTTP/1.1 200 OK
```

## Browser Verification

Use Playwright CLI for visual checks. Save screenshots under `output/playwright/`; that directory is ignored.

```powershell
$repoRoot = (git rev-parse --show-toplevel).Trim()
if ($repoRoot -notmatch '^[dD]:[/\\]') { throw 'Browser verification requires a D: drive checkout.' }
Set-Location $repoRoot
$screenshot = Join-Path $repoRoot 'output\playwright\flyte-console-projects.png'

npx --yes --package @playwright/cli playwright-cli -s=flyte-console-verify open http://172.19.66.218:30081/v2/projects
npx --yes --package @playwright/cli playwright-cli -s=flyte-console-verify snapshot
npx --yes --package @playwright/cli playwright-cli -s=flyte-console-verify console error
npx --yes --package @playwright/cli playwright-cli -s=flyte-console-verify requests
npx --yes --package @playwright/cli playwright-cli -s=flyte-console-verify screenshot --filename $screenshot --full-page
npx --yes --package @playwright/cli playwright-cli -s=flyte-console-verify close
```

Expected browser checks:

```text
Page title: Projects | Flyte 2
Visible project: flytesnacks
Console errors: 0
ListProjects request: 200
```

## Operational Notes

- `aione-flyte2` now supports direct root SSH. `kubectl` should work directly after `ssh aione-flyte2`.
- If `kubectl` connects to `localhost:8080`, the current user does not have kubeconfig. Use `sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl ...` or SSH as root.
- SSH NodePort login must use `ssh -p <port> user@host`; do not use `ssh host:port`.
- Long-running ML tasks stay running if their command contains `sleep 3600` or similar.
- For a short ML verification task, override the command with a short command.
