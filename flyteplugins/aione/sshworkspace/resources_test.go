package sshworkspace

import (
	"encoding/base64"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/types/known/structpb"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/util/validation"

	idlcore "github.com/flyteorg/flyte/v2/gen/go/flyteidl2/core"
)

func taskTemplateWithCustom(t *testing.T, values map[string]any) *idlcore.TaskTemplate {
	t.Helper()
	custom, err := structpb.NewStruct(values)
	require.NoError(t, err)
	return &idlcore.TaskTemplate{
		Type:   TaskType,
		Custom: custom,
	}
}

func TestParseConfigUsesCustomPayload(t *testing.T) {
	tmpl := taskTemplateWithCustom(t, map[string]any{
		"image":                    "ubuntu:22.04",
		"enableSsh":                true,
		"sshUser":                  "dev",
		"authorizedKeys":           []any{"ssh-rsa AAAA user@example"},
		"cpu":                      "1",
		"memory":                   "2Gi",
		"gpuCount":                 float64(1),
		"gpuModel":                 "NVIDIA T4",
		"serviceType":              "NodePort",
		"nodePort":                 float64(30222),
		"codeServerHost":           "run-abc-code.ops.fzyun.io",
		"imagePullSecretName":      "workspace-image-pull",
		"codeRepositorySecretName": "workspace-code-repos",
		"gpuNodeLabelKey":          "nvidia.com/gpu.present",
		"environment": map[string]any{
			"EXAMPLE": "value",
		},
		"codeRepositories": []any{map[string]any{
			"id":        "repo-1",
			"repoUrl":   "https://git.fzyun.io/serverless/aione.git",
			"branch":    "main",
			"mountPath": "/workspace/aione",
			"token":     "secret-token",
		}},
	})

	cfg, err := ParseConfig(tmpl)

	require.NoError(t, err)
	assert.Equal(t, "ubuntu:22.04", cfg.Image)
	assert.True(t, cfg.EnableSSH)
	assert.Equal(t, "dev", cfg.SSHUser)
	assert.Equal(t, []string{"ssh-rsa AAAA user@example"}, cfg.AuthorizedKeys)
	assert.Equal(t, "1", cfg.CPU)
	assert.Equal(t, "2Gi", cfg.Memory)
	assert.Equal(t, int32(1), cfg.GPUCount)
	assert.Equal(t, "NVIDIA T4", cfg.GPUModel)
	assert.Equal(t, "workspace-image-pull", cfg.ImagePullSecretName)
	assert.Equal(t, "workspace-code-repos", cfg.CodeRepositorySecretName)
	assert.Equal(t, "nvidia.com/gpu.present", cfg.GPUNodeLabelKey)
	assert.Equal(t, corev1.ServiceTypeNodePort, cfg.ServiceType)
	require.NotNil(t, cfg.NodePort)
	assert.Equal(t, int32(30222), *cfg.NodePort)
	assert.Equal(t, "run-abc-code.ops.fzyun.io", cfg.CodeServerHost)
	assert.Equal(t, map[string]string{"EXAMPLE": "value"}, cfg.Environment)
	require.Len(t, cfg.CodeRepositories, 1)
	assert.Equal(t, "repo-1", cfg.CodeRepositories[0].ID)
	assert.Equal(t, "/workspace/aione", cfg.CodeRepositories[0].MountPath)
}

func TestParseConfigDefaultsToOfficialIDEImage(t *testing.T) {
	tmpl := taskTemplateWithCustom(t, map[string]any{})

	cfg, err := ParseConfig(tmpl)

	require.NoError(t, err)
	assert.Equal(t, "docker.fzyun.io/founder/aione.ide:1.0.0.60", cfg.Image)
	assert.Equal(t, "flytekit", cfg.SSHUser)
	assert.False(t, cfg.EnableSSH)
	assert.Empty(t, cfg.AuthorizedKeys)
}

func TestParseConfigRejectsMissingAuthorizedKeysWhenSSHEnabled(t *testing.T) {
	tmpl := taskTemplateWithCustom(t, map[string]any{
		"image":     "ubuntu:22.04",
		"enableSsh": true,
		"sshUser":   "dev",
	})

	_, err := ParseConfig(tmpl)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "authorizedKeys")
}

func TestParseConfigRejectsInvalidServiceType(t *testing.T) {
	tmpl := taskTemplateWithCustom(t, map[string]any{
		"image":          "ubuntu:22.04",
		"enableSsh":      true,
		"sshUser":        "dev",
		"authorizedKeys": []any{"ssh-rsa AAAA user@example"},
		"serviceType":    "ExternalName",
	})

	_, err := ParseConfig(tmpl)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "serviceType")
}

func TestBuildResourcesCreatesSSHWorkspaceObjects(t *testing.T) {
	nodePort := int32(30222)
	cfg := WorkspaceConfig{
		Image:          "ubuntu:22.04",
		EnableSSH:      true,
		SSHUser:        "dev",
		AuthorizedKeys: []string{"ssh-rsa AAAA user@example"},
		CPU:            "1",
		Memory:         "2Gi",
		GPUCount:       1,
		GPUModel:       "NVIDIA T4",
		ServiceType:    corev1.ServiceTypeNodePort,
		NodePort:       &nodePort,
		Environment:    map[string]string{"EXAMPLE": "value"},
	}
	identity := WorkspaceIdentity{
		Namespace:  "flyte",
		Name:       "run-abc",
		RunName:    "run-abc",
		Project:    "flytesnacks",
		Domain:     "development",
		Org:        "testorg",
		ActionName: "main",
	}

	resources, err := BuildResources(identity, cfg)

	require.NoError(t, err)
	require.NotNil(t, resources.Secret)
	assert.Equal(t, "run-abc-ssh", resources.Secret.Name)
	assert.Equal(t, "flyte", resources.Secret.Namespace)
	assert.Equal(t, "ssh-rsa AAAA user@example\n", string(resources.Secret.Data["authorized_keys"]))
	assert.Nil(t, resources.PVC)

	sts := resources.StatefulSet
	require.IsType(t, &appsv1.StatefulSet{}, sts)
	assert.Equal(t, "run-abc", sts.Name)
	assert.Equal(t, int32(1), *sts.Spec.Replicas)
	require.Len(t, sts.Spec.Template.Spec.Containers, 1)
	container := sts.Spec.Template.Spec.Containers[0]
	assert.Equal(t, "ssh", container.Name)
	assert.Equal(t, "ubuntu:22.04", container.Image)
	require.NotNil(t, container.SecurityContext)
	require.NotNil(t, container.SecurityContext.RunAsUser)
	require.NotNil(t, container.SecurityContext.RunAsGroup)
	assert.Equal(t, int64(0), *container.SecurityContext.RunAsUser)
	assert.Equal(t, int64(0), *container.SecurityContext.RunAsGroup)
	assert.Contains(t, container.Command, "/bin/sh")
	assert.Contains(t, container.Args[0], "/usr/sbin/sshd -D -e")
	assert.Contains(t, container.Args[0], "code-server")
	assert.Contains(t, container.Args[0], "apt-get install -y --no-install-recommends openssh-server sudo ca-certificates")
	assert.Contains(t, container.Args[0], "useradd")
	assert.Contains(t, container.Args[0], "su - flytekit -c")
	assert.Contains(t, container.Args[0], "--auth none /home/flytekit")
	assert.NotContains(t, container.Args[0], "--auth none /workspace")
	assert.NotContains(t, container.Args[0], "mkdir -p /workspace")
	assert.NotContains(t, container.Args[0], "su - dev -c")
	assert.Contains(t, container.Args[0], "chown dev:dev /home/dev/.ssh /home/dev/.ssh/authorized_keys")
	assert.NotContains(t, container.Args[0], "chown -R dev:dev /home/dev")
	assert.NotContains(t, container.Args[0], "chown -R flytekit:flytekit /home/flytekit")
	assert.NotContains(t, container.Args[0], "chown -R flytekit:dev /workspace")
	assert.NotContains(t, container.Args[0], "chmod -R u+rwX,g+rwX /workspace")
	assert.Equal(t, "value", envValue(container.Env, "EXAMPLE"))
	gpuLimit := container.Resources.Limits[corev1.ResourceName("nvidia.com/gpu")]
	assert.Equal(t, "1", gpuLimit.String())
	assert.Equal(t, "NVIDIA-T4", sts.Labels[labelGPUModel])
	assert.Equal(t, "NVIDIA T4", sts.Annotations[annotationGPUModel])
	require.Len(t, container.Ports, 2)
	assert.Equal(t, int32(22), container.Ports[0].ContainerPort)
	assert.Equal(t, int32(8080), container.Ports[1].ContainerPort)
	assert.Equal(t, "code-server", container.Ports[1].Name)

	codeSvc := resources.CodeServerService
	assert.Equal(t, "run-abc-code", codeSvc.Name)
	assert.Equal(t, corev1.ServiceTypeClusterIP, codeSvc.Spec.Type)
	require.Len(t, codeSvc.Spec.Ports, 1)
	assert.Equal(t, "code-server", codeSvc.Spec.Ports[0].Name)
	assert.Equal(t, int32(8080), codeSvc.Spec.Ports[0].Port)
	assert.Equal(t, int32(0), codeSvc.Spec.Ports[0].NodePort)
	assert.Equal(t, "run-abc", codeSvc.Spec.Selector[labelWorkspaceName])

	sshSvc := resources.SSHService
	require.NotNil(t, sshSvc)
	assert.Equal(t, "run-abc-ssh", sshSvc.Name)
	assert.Equal(t, corev1.ServiceTypeNodePort, sshSvc.Spec.Type)
	require.Len(t, sshSvc.Spec.Ports, 1)
	assert.Equal(t, int32(22), sshSvc.Spec.Ports[0].Port)
	assert.Equal(t, int32(30222), sshSvc.Spec.Ports[0].NodePort)

	ingress := resources.CodeServerIngress
	require.IsType(t, &networkingv1.Ingress{}, ingress)
	assert.Equal(t, "run-abc-code", ingress.Name)
	assert.Equal(t, "flyte", ingress.Namespace)
	assert.Equal(t, "run-abc-code.ops.fzyun.io", ingress.Spec.Rules[0].Host)
	require.Len(t, ingress.Spec.Rules[0].HTTP.Paths, 1)
	path := ingress.Spec.Rules[0].HTTP.Paths[0]
	assert.Equal(t, "/", path.Path)
	require.NotNil(t, path.PathType)
	assert.Equal(t, networkingv1.PathTypePrefix, *path.PathType)
	assert.Equal(t, "run-abc-code", path.Backend.Service.Name)
	assert.Equal(t, networkingv1.ServiceBackendPort{Name: "code-server"}, path.Backend.Service.Port)
	assert.False(t, hasVolumeMount(container.VolumeMounts, "workspace", "/workspace"))
	assert.False(t, hasPVCVolume(sts.Spec.Template.Spec.Volumes, "workspace", "run-abc-workspace"))
	assert.False(t, hasEmptyDirVolume(sts.Spec.Template.Spec.Volumes, "workspace"))
}

func TestBuildResourcesDefaultsToIngressOnlyCodeServerWithoutSSH(t *testing.T) {
	cfg := WorkspaceConfig{
		Image: "ubuntu:22.04",
	}
	identity := WorkspaceIdentity{
		Namespace:  "flyte",
		Name:       "run-no-ssh",
		RunName:    "run-no-ssh",
		Project:    "flytesnacks",
		Domain:     "development",
		Org:        "testorg",
		ActionName: "main",
	}

	resources, err := BuildResources(identity, cfg)

	require.NoError(t, err)
	assert.Nil(t, resources.Secret)
	assert.Nil(t, resources.SSHService)
	require.NotNil(t, resources.CodeServerService)
	assert.Equal(t, corev1.ServiceTypeClusterIP, resources.CodeServerService.Spec.Type)
	require.Len(t, resources.CodeServerService.Spec.Ports, 1)
	assert.Equal(t, "code-server", resources.CodeServerService.Spec.Ports[0].Name)
	assert.Equal(t, int32(0), resources.CodeServerService.Spec.Ports[0].NodePort)

	container := resources.StatefulSet.Spec.Template.Spec.Containers[0]
	require.Len(t, container.Ports, 1)
	assert.Equal(t, "code-server", container.Ports[0].Name)
	assert.NotContains(t, container.Args[0], "apt-get")
	assert.NotContains(t, container.Args[0], "/usr/sbin/sshd")
	assert.Contains(t, container.Args[0], "AIONE_CODE_SERVER_STATUS")
	assert.Contains(t, container.Args[0], "CODE_SERVER_NOT_FOUND")
	assert.Contains(t, container.Args[0], "--auth none /home/flytekit")
	assert.NotContains(t, container.Args[0], "--auth none /workspace")
	assert.NotContains(t, container.Args[0], "mkdir -p /workspace")
	assert.NotContains(t, container.Args[0], "chown -R flytekit:flytekit /home/flytekit")
	assert.NotContains(t, container.Args[0], "chown -R flytekit:flytekit /workspace")
	assert.NotContains(t, container.Args[0], "chmod -R u+rwX,g+rwX /workspace")
	require.NotNil(t, container.ReadinessProbe)
	require.NotNil(t, container.ReadinessProbe.Exec)
	assert.Contains(t, strings.Join(container.ReadinessProbe.Exec.Command, " "), "/tmp/aione-workspace-ready")
	assert.False(t, hasVolumeMount(container.VolumeMounts, "workspace", "/workspace"))
	assert.False(t, hasEmptyDirVolume(resources.StatefulSet.Spec.Template.Spec.Volumes, "workspace"))
}

func TestBuildResourcesCreatesBoundedCodeServerIngressHost(t *testing.T) {
	cfg := WorkspaceConfig{
		Image:          "ubuntu:22.04",
		SSHUser:        "dev",
		AuthorizedKeys: []string{"ssh-rsa AAAA user@example"},
		ServiceType:    corev1.ServiceTypeClusterIP,
	}
	identity := WorkspaceIdentity{
		Namespace:  "flyte",
		Name:       "This_Run_Name_Is_Much_Longer_Than_A_DNS_Label_And_Needs_A_Hash_Suffix",
		RunName:    "This_Run_Name_Is_Much_Longer_Than_A_DNS_Label_And_Needs_A_Hash_Suffix",
		Project:    "flytesnacks",
		Domain:     "development",
		Org:        "testorg",
		ActionName: "main",
	}

	resources, err := BuildResources(identity, cfg)

	require.NoError(t, err)
	require.NotNil(t, resources.CodeServerIngress)
	host := resources.CodeServerIngress.Spec.Rules[0].Host
	assert.Contains(t, host, "-code.ops.fzyun.io")
	assert.Empty(t, validation.IsDNS1123Subdomain(host))
	assert.LessOrEqual(t, len(strings.TrimSuffix(host, ".ops.fzyun.io")), 63)
}

func TestBuildResourcesUsesExternalSecretsAndGPUNodeLabel(t *testing.T) {
	cfg := WorkspaceConfig{
		Image:                    "docker.fzyun.io/founder/aione.ide:1.0.0.60",
		ImagePullSecretName:      "workspace-image-pull",
		CodeRepositorySecretName: "workspace-code-repos",
		GPUNodeLabelKey:          "nvidia.com/gpu.present",
		SSHUser:                  "dev",
		AuthorizedKeys:           []string{"ssh-rsa AAAA user@example"},
		ServiceType:              corev1.ServiceTypeClusterIP,
		CodeRepositories: []CodeRepositoryMount{{
			ID:        "repo-1",
			RepoURL:   "https://git.fzyun.io/serverless/aione.git",
			Branch:    "main",
			MountPath: "/home/flytekit/aione",
		}},
	}
	identity := WorkspaceIdentity{
		Namespace:  "flyte",
		Name:       "run-abc",
		RunName:    "run-abc",
		Project:    "flytesnacks",
		Domain:     "development",
		Org:        "aione",
		ActionName: "main",
	}

	resources, err := BuildResources(identity, cfg)

	require.NoError(t, err)
	assert.Nil(t, resources.Secret)
	require.NotNil(t, resources.CodeDownloaderSecret)
	assert.Equal(t, "run-abc-code-downloader", resources.CodeDownloaderSecret.Name)
	podSpec := resources.StatefulSet.Spec.Template.Spec
	require.Len(t, podSpec.ImagePullSecrets, 1)
	assert.Equal(t, "workspace-image-pull", podSpec.ImagePullSecrets[0].Name)
	require.NotNil(t, podSpec.Affinity)
	require.NotNil(t, podSpec.Affinity.NodeAffinity)
	terms := podSpec.Affinity.NodeAffinity.RequiredDuringSchedulingIgnoredDuringExecution.NodeSelectorTerms
	require.Len(t, terms, 1)
	require.Len(t, terms[0].MatchExpressions, 1)
	assert.Equal(t, "nvidia.com/gpu.present", terms[0].MatchExpressions[0].Key)
	assert.Equal(t, corev1.NodeSelectorOpExists, terms[0].MatchExpressions[0].Operator)
	container := podSpec.Containers[0]
	assert.Empty(t, container.Env)
	require.Len(t, podSpec.InitContainers, 1)
	assert.Equal(t, "code-downloader", podSpec.InitContainers[0].Name)
	assert.Equal(t, "run-abc-code-downloader", podSpec.InitContainers[0].Env[0].ValueFrom.SecretKeyRef.Name)
}

func TestBuildResourcesAddsCloudStoragePVCMounts(t *testing.T) {
	cfg := WorkspaceConfig{
		Image:          "ubuntu:22.04",
		SSHUser:        "dev",
		AuthorizedKeys: []string{"ssh-rsa AAAA user@example"},
		ServiceType:    corev1.ServiceTypeClusterIP,
		CloudStorageMounts: []CloudStorageMount{{
			ID:           "storage-1",
			PVCName:      "storage-1-flyte",
			StorageClass: "bj1-ebs",
			Size:         "100Gi",
			MountPath:    "/mnt/cloud/dataset",
		}},
	}
	identity := WorkspaceIdentity{
		Namespace:  "flyte",
		Name:       "run-abc",
		RunName:    "run-abc",
		Project:    "flytesnacks",
		Domain:     "development",
		Org:        "testorg",
		ActionName: "main",
	}

	resources, err := BuildResources(identity, cfg)

	require.NoError(t, err)
	require.Len(t, resources.CloudStoragePVCs, 1)
	pvc := resources.CloudStoragePVCs[0]
	assert.Equal(t, "storage-1-flyte", pvc.Name)
	assert.Equal(t, "flyte", pvc.Namespace)
	require.NotNil(t, pvc.Spec.StorageClassName)
	assert.Equal(t, "bj1-ebs", *pvc.Spec.StorageClassName)
	assert.Equal(t, "100Gi", pvc.Spec.Resources.Requests.Storage().String())
	assert.Equal(t, "storage-1", pvc.Labels["flyte.org/cloud-storage-id"])

	podSpec := resources.StatefulSet.Spec.Template.Spec
	assert.True(t, hasPVCVolume(podSpec.Volumes, "cloud-storage-0", "storage-1-flyte"))
	container := podSpec.Containers[0]
	assert.True(t, hasVolumeMount(container.VolumeMounts, "cloud-storage-0", "/mnt/cloud/dataset"))
}

func TestBuildResourcesAddsCodeRepositoryDownloader(t *testing.T) {
	cfg := WorkspaceConfig{
		Image:           "ubuntu:22.04",
		SSHUser:         "dev",
		AuthorizedKeys:  []string{"ssh-rsa AAAA user@example"},
		ServiceType:     corev1.ServiceTypeClusterIP,
		DownloaderImage: "aione-downloader:main-abc1234",
		CodeRepositories: []CodeRepositoryMount{{
			ID:        "repo-1",
			RepoURL:   "https://git.fzyun.io/serverless/aione.git",
			Branch:    "main",
			MountPath: "/home/flytekit/aione",
			Token:     "secret-token",
		}},
	}
	identity := WorkspaceIdentity{
		Namespace:  "flyte",
		Name:       "run-abc",
		RunName:    "run-abc",
		Project:    "flytesnacks",
		Domain:     "development",
		Org:        "testorg",
		ActionName: "main",
	}

	resources, err := BuildResources(identity, cfg)

	require.NoError(t, err)
	require.NotNil(t, resources.CodeDownloaderSecret)
	assert.Equal(t, "run-abc-code-downloader", resources.CodeDownloaderSecret.Name)
	secretPayload := decodedDownloaderSecret(t, resources.CodeDownloaderSecret)
	assert.NotContains(t, string(resources.CodeDownloaderSecret.Data["aione_params"]), "secret-token")
	assert.Contains(t, secretPayload, "secret-token")
	podSpec := resources.StatefulSet.Spec.Template.Spec
	require.Len(t, podSpec.InitContainers, 1)
	initContainer := podSpec.InitContainers[0]
	assert.Equal(t, "code-downloader", initContainer.Name)
	assert.Equal(t, "aione-downloader:main-abc1234", initContainer.Image)
	assert.Equal(t, corev1.PullIfNotPresent, initContainer.ImagePullPolicy)
	assert.Equal(t, "AIONE_PARAMS", initContainer.Env[0].Name)
	assert.True(t, hasEmptyDirVolume(podSpec.Volumes, "code-repository-0"))
	assert.True(t, hasVolumeMount(initContainer.VolumeMounts, "code-repository-0", "/home/flytekit/aione"))

	container := podSpec.Containers[0]
	assert.Empty(t, envName(container.Env, "AIONE_PARAMS"))
	assert.NotContains(t, container.Args[0], "download GitLab archive repositories")
	assert.True(t, hasVolumeMount(container.VolumeMounts, "code-repository-0", "/home/flytekit/aione"))
}

func TestBuildResourcesAddsDatasetDownloader(t *testing.T) {
	cfg := WorkspaceConfig{
		Image:           "ubuntu:22.04",
		SSHUser:         "dev",
		AuthorizedKeys:  []string{"ssh-rsa AAAA user@example"},
		ServiceType:     corev1.ServiceTypeClusterIP,
		DownloaderImage: "aione-downloader:main-abc1234",
		Datasets: []RuntimeDataset{{
			Endpoint:   "1.2.3.4",
			Port:       "9000",
			AccessKey:  "ak",
			SecretKey:  "sk",
			TargetPath: "/data/set1",
			Bucket:     "mybucket1",
			BucketPath: "",
		}},
	}
	identity := WorkspaceIdentity{
		Namespace:  "flyte",
		Name:       "run-abc",
		RunName:    "run-abc",
		Project:    "flytesnacks",
		Domain:     "development",
		Org:        "testorg",
		ActionName: "main",
	}

	resources, err := BuildResources(identity, cfg)

	require.NoError(t, err)
	require.NotNil(t, resources.DatasetDownloaderSecret)
	secretPayload := decodedDownloaderSecret(t, resources.DatasetDownloaderSecret)
	assert.Contains(t, secretPayload, "mybucket1")
	podSpec := resources.StatefulSet.Spec.Template.Spec
	require.Len(t, podSpec.InitContainers, 1)
	initContainer := podSpec.InitContainers[0]
	assert.Equal(t, "dataset-downloader", initContainer.Name)
	assert.True(t, hasEmptyDirVolume(podSpec.Volumes, "dataset-0"))
	assert.True(t, hasVolumeMount(initContainer.VolumeMounts, "dataset-0", "/data/set1"))

	container := podSpec.Containers[0]
	assert.True(t, hasVolumeMount(container.VolumeMounts, "dataset-0", "/data/set1"))
}

func TestBuildResourcesUsesValidKubernetesNamesWhenRunStartsWithDigit(t *testing.T) {
	nodePort := int32(30222)
	cfg := WorkspaceConfig{
		Image:          "ubuntu:22.04",
		SSHUser:        "dev",
		AuthorizedKeys: []string{"ssh-rsa AAAA user@example"},
		ServiceType:    corev1.ServiceTypeNodePort,
		NodePort:       &nodePort,
	}
	identity := WorkspaceIdentity{
		Namespace:  "flyte",
		Name:       "1111-a0-0",
		RunName:    "1111",
		Project:    "flytesnacks",
		Domain:     "development",
		Org:        "testorg",
		ActionName: "a0",
	}

	resources, err := BuildResources(identity, cfg)

	require.NoError(t, err)
	assert.Empty(t, validation.IsDNS1035Label(resources.CodeServerService.Name))
	assert.Empty(t, validation.IsDNS1123Subdomain(resources.StatefulSet.Name))
	assert.Nil(t, resources.PVC)
	assert.Equal(t, "1111-a0-0", resources.CodeServerService.Spec.Selector[labelWorkspaceName])
	assert.Equal(t, "1111-a0-0", resources.StatefulSet.Spec.Selector.MatchLabels[labelWorkspaceName])
	assert.Equal(t, "1111-a0-0", resources.StatefulSet.Spec.Template.Labels[labelWorkspaceName])
}

func hasPVCVolume(volumes []corev1.Volume, name, claimName string) bool {
	for _, volume := range volumes {
		if volume.Name == name && volume.PersistentVolumeClaim != nil && volume.PersistentVolumeClaim.ClaimName == claimName {
			return true
		}
	}
	return false
}

func hasEmptyDirVolume(volumes []corev1.Volume, name string) bool {
	for _, volume := range volumes {
		if volume.Name == name && volume.EmptyDir != nil {
			return true
		}
	}
	return false
}

func decodedDownloaderSecret(t *testing.T, secret *corev1.Secret) string {
	t.Helper()
	decoded, err := base64.StdEncoding.DecodeString(string(secret.Data["aione_params"]))
	require.NoError(t, err)
	return string(decoded)
}

func hasVolumeMount(mounts []corev1.VolumeMount, name, mountPath string) bool {
	for _, mount := range mounts {
		if mount.Name == name && mount.MountPath == mountPath {
			return true
		}
	}
	return false
}

func envValue(env []corev1.EnvVar, name string) string {
	for _, e := range env {
		if e.Name == name {
			return e.Value
		}
	}
	return ""
}

func envName(env []corev1.EnvVar, name string) string {
	for _, e := range env {
		if e.Name == name {
			return e.Name
		}
	}
	return ""
}
