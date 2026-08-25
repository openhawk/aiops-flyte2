# aione-downloader 镜像策略

`aione-downloader` 是模型、代码和数据下载初始化容器。正式部署使用与后端提交一致的不可变标签：

```text
docker.ops.fzyun.io/aione-downloader:main-<commit>
```

`scripts/deploy-aiops-flyte.sh` 每次部署都会构建 commit 标签和兼容用的 `latest` 标签，通过受控
Registry 写窗口推送两个标签，再把 Flyte 服务的 `AIONE_DOWNLOADER_IMAGE` 设置为 commit 标签。
模型 Pod 的初始化容器使用 `IfNotPresent`：节点已经存在该镜像时直接复用，否则从
`docker.ops.fzyun.io` 拉取。

基础镜像使用内部仓库的标准 library 路径 `docker.fzyun.io/library/python:3.12-slim`，不要省略
`library/`；省略后可能命中只有索引、缺少实际 manifest 的旧仓库路径，导致 downloader 构建失败。

因此 downloader 的更新方式是重新执行正式部署脚本。部署后可用以下命令确认 Registry 镜像和
运行时配置一致：

```bash
curl -fsS https://docker.ops.fzyun.io/v2/aione-downloader/tags/list
kubectl -n flyte get deploy flyte-binary -o yaml | grep -A2 AIONE_DOWNLOADER_IMAGE
```

如果模型 Pod 仍引用历史标签，先确认 Flyte 服务已滚动到新配置，然后停止并重新启动该模型，
使控制器使用当前 commit 标签重新生成 Pod。
