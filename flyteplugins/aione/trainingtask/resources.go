package trainingtask

import (
	"fmt"
	"hash/fnv"
	"strings"
	"unicode"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	aionedownloader "github.com/flyteorg/flyte/v2/flyteplugins/aione/downloader"
)

const (
	labelTrainingTaskName = "flyte.org/training-task"
	labelRunName          = "flyte.org/run-name"
	labelProject          = "flyte.org/project"
	labelDomain           = "flyte.org/domain"
	labelOrg              = "flyte.org/org"
	labelActionName       = "flyte.org/action-name"
	labelGPUModel         = "flyte.org/gpu-model"

	annotationBandwidth = "flyte.org/network-bandwidth"
	annotationGPUModel  = "flyte.org/gpu-model"

	maxGeneratedNameBaseLength = 63
)

type TrainingIdentity struct {
	Namespace  string
	Name       string
	RunName    string
	Project    string
	Domain     string
	Org        string
	ActionName string
}

type TrainingResources struct {
	Job                     *batchv1.Job
	CloudStoragePVCs        []*corev1.PersistentVolumeClaim
	CodeRepositorySecret    *corev1.Secret
	CodeDownloaderSecret    *corev1.Secret
	DatasetDownloaderSecret *corev1.Secret
}

func BuildResources(identity TrainingIdentity, cfg TrainingConfig) (TrainingResources, error) {
	if identity.Namespace == "" {
		return TrainingResources{}, fmt.Errorf("namespace is required")
	}
	if identity.Name == "" {
		return TrainingResources{}, fmt.Errorf("name is required")
	}
	if cfg.Image == "" {
		return TrainingResources{}, fmt.Errorf("image is required")
	}
	if cfg.Command == "" {
		return TrainingResources{}, fmt.Errorf("command is required")
	}

	var cpu, memory resource.Quantity
	var err error
	if cfg.CPU != "" {
		cpu, err = resource.ParseQuantity(cfg.CPU)
		if err != nil {
			return TrainingResources{}, fmt.Errorf("invalid cpu quantity: %w", err)
		}
	}
	if cfg.Memory != "" {
		memory, err = resource.ParseQuantity(cfg.Memory)
		if err != nil {
			return TrainingResources{}, fmt.Errorf("invalid memory quantity: %w", err)
		}
	}

	labels := trainingLabels(identity)
	if cfg.GPUModel != "" {
		labels[labelGPUModel] = sanitizeLabelValue(cfg.GPUModel)
	}
	annotations := map[string]string{}
	if cfg.Bandwidth != "" {
		annotations[annotationBandwidth] = cfg.Bandwidth
	}
	if cfg.GPUModel != "" {
		annotations[annotationGPUModel] = cfg.GPUModel
	}

	resourceName := kubernetesNameBase(identity.Name)
	container := corev1.Container{
		Name:            "training",
		Image:           cfg.Image,
		ImagePullPolicy: corev1.PullIfNotPresent,
		Command:         []string{"/bin/sh", "-c"},
		Args:            []string{cfg.Command},
	}
	var codeDownloaderSecret *corev1.Secret
	var datasetDownloaderSecret *corev1.Secret
	initContainers := []corev1.Container{}
	volumes := make([]corev1.Volume, 0, len(cfg.CloudStorageMounts)+len(cfg.CodeRepositories)+len(cfg.Datasets))
	if len(cfg.CodeRepositories) > 0 {
		secretName := resourceName + "-code-downloader"
		params := aionedownloader.Params{Codes: make([]aionedownloader.Code, 0, len(cfg.CodeRepositories))}
		volumeMounts := make([]corev1.VolumeMount, 0, len(cfg.CodeRepositories))
		for i, repo := range cfg.CodeRepositories {
			volumeName := fmt.Sprintf("code-repository-%d", i)
			volumes = append(volumes, corev1.Volume{
				Name:         volumeName,
				VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
			})
			mount := corev1.VolumeMount{Name: volumeName, MountPath: repo.MountPath}
			volumeMounts = append(volumeMounts, mount)
			container.VolumeMounts = append(container.VolumeMounts, mount)
			params.Codes = append(params.Codes, aionedownloader.Code{
				ID:     repo.RepoURL,
				Path:   repo.MountPath,
				Token:  repo.Token,
				Branch: repo.Branch,
			})
		}
		data, err := aionedownloader.SecretValue(params)
		if err != nil {
			return TrainingResources{}, err
		}
		codeDownloaderSecret = &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      secretName,
				Namespace: identity.Namespace,
				Labels:    labels,
			},
			Type: corev1.SecretTypeOpaque,
			Data: map[string][]byte{aionedownloader.SecretKey: data},
		}
		initContainers = append(initContainers, corev1.Container{
			Name:            "code-downloader",
			Image:           aionedownloader.Image(cfg.DownloaderImage),
			ImagePullPolicy: corev1.PullIfNotPresent,
			Env:             []corev1.EnvVar{aionedownloader.EnvVar(secretName)},
			VolumeMounts:    volumeMounts,
		})
	}
	if len(cfg.Datasets) > 0 {
		secretName := resourceName + "-dataset-downloader"
		params := aionedownloader.Params{OSSDatas: make([]aionedownloader.OSSData, 0, len(cfg.Datasets))}
		volumeMounts := make([]corev1.VolumeMount, 0, len(cfg.Datasets))
		for i, dataset := range cfg.Datasets {
			volumeName := fmt.Sprintf("dataset-%d", i)
			volumes = append(volumes, corev1.Volume{
				Name:         volumeName,
				VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
			})
			mount := corev1.VolumeMount{Name: volumeName, MountPath: dataset.TargetPath}
			volumeMounts = append(volumeMounts, mount)
			container.VolumeMounts = append(container.VolumeMounts, mount)
			params.OSSDatas = append(params.OSSDatas, aionedownloader.OSSData{
				Endpoint:   dataset.Endpoint,
				Port:       dataset.Port,
				AccessKey:  dataset.AccessKey,
				SecretKey:  dataset.SecretKey,
				TargetPath: dataset.TargetPath,
				Bucket:     dataset.Bucket,
				BucketPath: dataset.BucketPath,
			})
		}
		data, err := aionedownloader.SecretValue(params)
		if err != nil {
			return TrainingResources{}, err
		}
		datasetDownloaderSecret = &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      secretName,
				Namespace: identity.Namespace,
				Labels:    labels,
			},
			Type: corev1.SecretTypeOpaque,
			Data: map[string][]byte{aionedownloader.SecretKey: data},
		}
		initContainers = append(initContainers, corev1.Container{
			Name:            "dataset-downloader",
			Image:           aionedownloader.Image(cfg.DownloaderImage),
			ImagePullPolicy: corev1.PullIfNotPresent,
			Env:             []corev1.EnvVar{aionedownloader.EnvVar(secretName)},
			VolumeMounts:    volumeMounts,
		})
	}
	if !cpu.IsZero() {
		if container.Resources.Requests == nil {
			container.Resources.Requests = corev1.ResourceList{}
		}
		container.Resources.Requests[corev1.ResourceCPU] = cpu
	}
	if !memory.IsZero() {
		if container.Resources.Requests == nil {
			container.Resources.Requests = corev1.ResourceList{}
		}
		container.Resources.Requests[corev1.ResourceMemory] = memory
	}
	if cfg.GPUCount > 0 {
		gpu := resource.MustParse(fmt.Sprintf("%d", cfg.GPUCount))
		if container.Resources.Requests == nil {
			container.Resources.Requests = corev1.ResourceList{}
		}
		if container.Resources.Limits == nil {
			container.Resources.Limits = corev1.ResourceList{}
		}
		container.Resources.Requests[corev1.ResourceName("nvidia.com/gpu")] = gpu
		container.Resources.Limits[corev1.ResourceName("nvidia.com/gpu")] = gpu
	}
	cloudPVCs := make([]*corev1.PersistentVolumeClaim, 0, len(cfg.CloudStorageMounts))
	for i, mount := range cfg.CloudStorageMounts {
		size, err := resource.ParseQuantity(mount.Size)
		if err != nil {
			return TrainingResources{}, fmt.Errorf("invalid cloud storage size: %w", err)
		}
		volumeName := fmt.Sprintf("cloud-storage-%d", i)
		storageClass := mount.StorageClass
		cloudPVCs = append(cloudPVCs, &corev1.PersistentVolumeClaim{
			ObjectMeta: metav1.ObjectMeta{
				Name:      mount.PVCName,
				Namespace: identity.Namespace,
				Labels: mergeLabels(labels, map[string]string{
					"flyte.org/cloud-storage":    "true",
					"flyte.org/cloud-storage-id": mount.ID,
				}),
			},
			Spec: corev1.PersistentVolumeClaimSpec{
				AccessModes:      []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
				StorageClassName: &storageClass,
				Resources: corev1.VolumeResourceRequirements{
					Requests: corev1.ResourceList{corev1.ResourceStorage: size},
				},
			},
		})
		volumes = append(volumes, corev1.Volume{
			Name: volumeName,
			VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: mount.PVCName},
			},
		})
		container.VolumeMounts = append(container.VolumeMounts, corev1.VolumeMount{
			Name:      volumeName,
			MountPath: mount.MountPath,
		})
	}

	backoffLimit := int32(0)
	var activeDeadlineSeconds *int64
	if cfg.MaxRuntimeHours > 0 {
		seconds := int64(cfg.MaxRuntimeHours) * 3600
		activeDeadlineSeconds = &seconds
	}
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:        resourceName,
			Namespace:   identity.Namespace,
			Labels:      labels,
			Annotations: annotations,
		},
		Spec: batchv1.JobSpec{
			BackoffLimit:          &backoffLimit,
			ActiveDeadlineSeconds: activeDeadlineSeconds,
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels, Annotations: annotations},
				Spec: corev1.PodSpec{
					RestartPolicy:  corev1.RestartPolicyNever,
					InitContainers: initContainers,
					Containers:     []corev1.Container{container},
					Volumes:        volumes,
				},
			},
		},
	}

	return TrainingResources{Job: job, CloudStoragePVCs: cloudPVCs, CodeDownloaderSecret: codeDownloaderSecret, DatasetDownloaderSecret: datasetDownloaderSecret}, nil
}

func trainingLabels(identity TrainingIdentity) map[string]string {
	return map[string]string{
		labelTrainingTaskName: identity.Name,
		labelRunName:          identity.RunName,
		labelProject:          identity.Project,
		labelDomain:           identity.Domain,
		labelOrg:              identity.Org,
		labelActionName:       identity.ActionName,
	}
}

func mergeLabels(base map[string]string, extra map[string]string) map[string]string {
	labels := make(map[string]string, len(base)+len(extra))
	for key, value := range base {
		labels[key] = value
	}
	for key, value := range extra {
		labels[key] = value
	}
	return labels
}

func kubernetesNameBase(name string) string {
	var builder strings.Builder
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z':
			builder.WriteRune(r)
		case r >= '0' && r <= '9':
			builder.WriteRune(r)
		case r == '-':
			builder.WriteRune(r)
		default:
			builder.WriteRune('-')
		}
	}

	cleaned := collapseHyphens(strings.Trim(builder.String(), "-"))
	if cleaned == "" {
		cleaned = "training"
	}
	if !unicode.IsLetter(rune(cleaned[0])) {
		cleaned = "training-" + cleaned
	}
	if len(cleaned) <= maxGeneratedNameBaseLength {
		return cleaned
	}

	hash := shortNameHash(cleaned)
	prefixLength := maxGeneratedNameBaseLength - len(hash) - 1
	return strings.TrimRight(cleaned[:prefixLength], "-") + "-" + hash
}

func collapseHyphens(value string) string {
	var builder strings.Builder
	lastHyphen := false
	for _, r := range value {
		if r == '-' {
			if lastHyphen {
				continue
			}
			lastHyphen = true
		} else {
			lastHyphen = false
		}
		builder.WriteRune(r)
	}
	return builder.String()
}

func shortNameHash(value string) string {
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(value))
	return fmt.Sprintf("%08x", hash.Sum32())
}

func sanitizeLabelValue(value string) string {
	cleaned := strings.NewReplacer(" ", "-", "/", "-", "_", "-").Replace(strings.TrimSpace(value))
	return strings.Trim(cleaned, "-")
}
