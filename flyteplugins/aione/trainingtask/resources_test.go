package trainingtask

import (
	"encoding/base64"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"

	idlcore "github.com/flyteorg/flyte/v2/gen/go/flyteidl2/core"
	"google.golang.org/protobuf/types/known/structpb"
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

func TestParseConfigUsesTrainingTaskPayload(t *testing.T) {
	tmpl := taskTemplateWithCustom(t, map[string]any{
		"image":           "busybox:1.36",
		"command":         "echo hello",
		"cpu":             "8",
		"memory":          "16Gi",
		"gpuCount":        float64(1),
		"gpuModel":        "NVIDIA T4",
		"bandwidth":       "1Gbps",
		"maxRuntimeHours": float64(2),
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
	assert.Equal(t, "busybox:1.36", cfg.Image)
	assert.Equal(t, "echo hello", cfg.Command)
	assert.Equal(t, "8", cfg.CPU)
	assert.Equal(t, "16Gi", cfg.Memory)
	assert.Equal(t, int32(1), cfg.GPUCount)
	assert.Equal(t, "NVIDIA T4", cfg.GPUModel)
	assert.Equal(t, "1Gbps", cfg.Bandwidth)
	assert.Equal(t, int32(2), cfg.MaxRuntimeHours)
	require.Len(t, cfg.CodeRepositories, 1)
	assert.Equal(t, "repo-1", cfg.CodeRepositories[0].ID)
	assert.Equal(t, "/workspace/aione", cfg.CodeRepositories[0].MountPath)
}

func TestParseConfigRejectsMissingCommand(t *testing.T) {
	tmpl := taskTemplateWithCustom(t, map[string]any{
		"image": "busybox:1.36",
	})

	_, err := ParseConfig(tmpl)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "command")
}

func TestBuildResourcesCreatesTrainingJob(t *testing.T) {
	cfg := TrainingConfig{
		Image:           "busybox:1.36",
		Command:         "echo hello",
		CPU:             "8",
		Memory:          "16Gi",
		GPUCount:        1,
		GPUModel:        "NVIDIA T4",
		Bandwidth:       "1Gbps",
		MaxRuntimeHours: 2,
	}
	identity := TrainingIdentity{
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
	require.NotNil(t, resources.Job)
	assert.Equal(t, "run-abc", resources.Job.Name)
	assert.Equal(t, "flyte", resources.Job.Namespace)
	require.NotNil(t, resources.Job.Spec.ActiveDeadlineSeconds)
	assert.Equal(t, int64(7200), *resources.Job.Spec.ActiveDeadlineSeconds)
	require.NotNil(t, resources.Job.Spec.BackoffLimit)
	assert.Equal(t, int32(0), *resources.Job.Spec.BackoffLimit)

	podSpec := resources.Job.Spec.Template.Spec
	assert.Equal(t, corev1.RestartPolicyNever, podSpec.RestartPolicy)
	require.Len(t, podSpec.Containers, 1)
	container := podSpec.Containers[0]
	assert.Equal(t, "training", container.Name)
	assert.Equal(t, "busybox:1.36", container.Image)
	assert.Equal(t, []string{"/bin/sh", "-c"}, container.Command)
	assert.Equal(t, []string{"echo hello"}, container.Args)
	assert.Equal(t, "8", container.Resources.Requests.Cpu().String())
	assert.Equal(t, "16Gi", container.Resources.Requests.Memory().String())
	gpuLimit := container.Resources.Limits[corev1.ResourceName("nvidia.com/gpu")]
	assert.Equal(t, "1", gpuLimit.String())
	assert.Equal(t, "NVIDIA-T4", resources.Job.Labels[labelGPUModel])
	assert.Equal(t, "NVIDIA T4", resources.Job.Annotations[annotationGPUModel])
	assert.Equal(t, "1Gbps", resources.Job.Annotations[annotationBandwidth])
}

func TestBuildResourcesAddsCloudStoragePVCMounts(t *testing.T) {
	cfg := TrainingConfig{
		Image:   "busybox:1.36",
		Command: "echo hello",
		CPU:     "2",
		Memory:  "4Gi",
		CloudStorageMounts: []CloudStorageMount{{
			ID:           "storage-1",
			PVCName:      "storage-1-flyte",
			StorageClass: "bj1-ebs",
			Size:         "100Gi",
			MountPath:    "/mnt/cloud/dataset",
		}},
	}
	identity := TrainingIdentity{
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

	podSpec := resources.Job.Spec.Template.Spec
	assert.True(t, hasPVCVolume(podSpec.Volumes, "cloud-storage-0", "storage-1-flyte"))
	container := podSpec.Containers[0]
	assert.True(t, hasVolumeMount(container.VolumeMounts, "cloud-storage-0", "/mnt/cloud/dataset"))
}

func TestBuildResourcesAddsCodeRepositoryDownloader(t *testing.T) {
	cfg := TrainingConfig{
		Image:           "busybox:1.36",
		Command:         "echo hello",
		CPU:             "2",
		Memory:          "4Gi",
		DownloaderImage: "aione-downloader:main-abc1234",
		CodeRepositories: []CodeRepositoryMount{{
			ID:        "repo-1",
			RepoURL:   "https://git.fzyun.io/serverless/aione.git",
			Branch:    "main",
			MountPath: "/workspace/aione",
			Token:     "secret-token",
		}},
	}
	identity := TrainingIdentity{
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

	podSpec := resources.Job.Spec.Template.Spec
	require.Len(t, podSpec.InitContainers, 1)
	initContainer := podSpec.InitContainers[0]
	assert.Equal(t, "code-downloader", initContainer.Name)
	assert.Equal(t, "aione-downloader:main-abc1234", initContainer.Image)
	assert.Equal(t, corev1.PullIfNotPresent, initContainer.ImagePullPolicy)
	assert.Equal(t, "AIONE_PARAMS", initContainer.Env[0].Name)
	assert.Equal(t, "run-abc-code-downloader", initContainer.Env[0].ValueFrom.SecretKeyRef.Name)
	assert.True(t, hasEmptyDirVolume(podSpec.Volumes, "code-repository-0"))
	assert.True(t, hasVolumeMount(initContainer.VolumeMounts, "code-repository-0", "/workspace/aione"))

	container := podSpec.Containers[0]
	assert.Empty(t, container.Env)
	assert.Equal(t, []string{"echo hello"}, container.Args)
	assert.True(t, hasVolumeMount(container.VolumeMounts, "code-repository-0", "/workspace/aione"))
}

func TestBuildResourcesAddsDatasetDownloader(t *testing.T) {
	cfg := TrainingConfig{
		Image:           "busybox:1.36",
		Command:         "echo hello",
		DownloaderImage: "aione-downloader:main-abc1234",
		Datasets: []RuntimeDataset{{
			Endpoint:   "1.2.3.4",
			Port:       "9000",
			AccessKey:  "ak",
			SecretKey:  "sk",
			TargetPath: "/data/set1",
			Bucket:     "mybucket1",
			BucketPath: "sub-path/xxx",
		}},
	}
	identity := TrainingIdentity{
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
	assert.Equal(t, "run-abc-dataset-downloader", resources.DatasetDownloaderSecret.Name)
	secretPayload := decodedDownloaderSecret(t, resources.DatasetDownloaderSecret)
	assert.Contains(t, secretPayload, "mybucket1")
	assert.NotContains(t, secretPayload, "cloud_storage_id")

	podSpec := resources.Job.Spec.Template.Spec
	require.Len(t, podSpec.InitContainers, 1)
	initContainer := podSpec.InitContainers[0]
	assert.Equal(t, "dataset-downloader", initContainer.Name)
	assert.Equal(t, "aione-downloader:main-abc1234", initContainer.Image)
	assert.Equal(t, corev1.PullIfNotPresent, initContainer.ImagePullPolicy)
	assert.True(t, hasEmptyDirVolume(podSpec.Volumes, "dataset-0"))
	assert.True(t, hasVolumeMount(initContainer.VolumeMounts, "dataset-0", "/data/set1"))

	container := podSpec.Containers[0]
	assert.Equal(t, []string{"echo hello"}, container.Args)
	assert.True(t, hasVolumeMount(container.VolumeMounts, "dataset-0", "/data/set1"))
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
