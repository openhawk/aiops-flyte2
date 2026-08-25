package sshworkspace

import (
	"fmt"
	"hash/fnv"
	"sort"
	"strings"
	"unicode"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"

	aionedownloader "github.com/flyteorg/flyte/v2/flyteplugins/aione/downloader"
)

const (
	labelWorkspaceName = "flyte.org/ssh-workspace"
	labelRunName       = "flyte.org/run-name"
	labelProject       = "flyte.org/project"
	labelDomain        = "flyte.org/domain"
	labelOrg           = "flyte.org/org"
	labelActionName    = "flyte.org/action-name"
	labelGPUModel      = "flyte.org/gpu-model"

	annotationGPUModel = "flyte.org/gpu-model"

	maxGeneratedNameBaseLength = 63 - len("-workspace")
	codeServerDomain           = "ops.fzyun.io"
)

type WorkspaceIdentity struct {
	Namespace  string
	Name       string
	RunName    string
	Project    string
	Domain     string
	Org        string
	ActionName string
}

type WorkspaceResources struct {
	Secret                  *corev1.Secret
	CodeDownloaderSecret    *corev1.Secret
	DatasetDownloaderSecret *corev1.Secret
	PVC                     *corev1.PersistentVolumeClaim
	CloudStoragePVCs        []*corev1.PersistentVolumeClaim
	StatefulSet             *appsv1.StatefulSet
	CodeServerService       *corev1.Service
	SSHService              *corev1.Service
	CodeServerIngress       *networkingv1.Ingress
}

func BuildResources(identity WorkspaceIdentity, cfg WorkspaceConfig) (WorkspaceResources, error) {
	if identity.Namespace == "" {
		return WorkspaceResources{}, fmt.Errorf("namespace is required")
	}
	if identity.Name == "" {
		return WorkspaceResources{}, fmt.Errorf("name is required")
	}

	labels := workspaceLabels(identity)
	if cfg.GPUModel != "" {
		labels[labelGPUModel] = sanitizeLabelValue(cfg.GPUModel)
	}
	annotations := map[string]string{}
	if cfg.GPUModel != "" {
		annotations[annotationGPUModel] = cfg.GPUModel
	}
	resourceName := kubernetesNameBase(identity.Name)
	secretName := resourceName + "-ssh"
	codeServerServiceName := resourceName + "-code"
	sshServiceName := resourceName + "-ssh"

	var cpu, memory resource.Quantity
	var err error
	if cfg.CPU != "" {
		cpu, err = resource.ParseQuantity(cfg.CPU)
		if err != nil {
			return WorkspaceResources{}, fmt.Errorf("invalid cpu quantity: %w", err)
		}
	}
	if cfg.Memory != "" {
		memory, err = resource.ParseQuantity(cfg.Memory)
		if err != nil {
			return WorkspaceResources{}, fmt.Errorf("invalid memory quantity: %w", err)
		}
	}

	var secret *corev1.Secret
	if cfg.EnableSSH {
		secret = &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      secretName,
				Namespace: identity.Namespace,
				Labels:    labels,
			},
			Type: corev1.SecretTypeOpaque,
			Data: map[string][]byte{},
		}
		if cfg.EnableSSH {
			secret.Data["authorized_keys"] = []byte(strings.Join(cfg.AuthorizedKeys, "\n") + "\n")
		}
	}

	replicas := int32(1)
	rootUser := int64(0)
	entrypoint := workspaceEntrypoint(cfg.EnableSSH, cfg.SSHUser)
	containerPorts := []corev1.ContainerPort{{
		Name:          "code-server",
		ContainerPort: 8080,
		Protocol:      corev1.ProtocolTCP,
	}}
	volumeMounts := []corev1.VolumeMount{}
	volumes := []corev1.Volume{}
	initContainers := []corev1.Container{}
	if cfg.EnableSSH {
		containerPorts = append([]corev1.ContainerPort{{
			Name:          "ssh",
			ContainerPort: 22,
			Protocol:      corev1.ProtocolTCP,
		}}, containerPorts...)
		volumeMounts = append(volumeMounts, corev1.VolumeMount{
			Name:      "ssh-keys",
			MountPath: "/flyte-ssh",
			ReadOnly:  true,
		})
		volumes = append(volumes, corev1.Volume{
			Name: "ssh-keys",
			VolumeSource: corev1.VolumeSource{
				Secret: &corev1.SecretVolumeSource{SecretName: secretName},
			},
		})
	}
	readinessCommand := "test -f /tmp/aione-workspace-ready"
	if cfg.EnableSSH {
		readinessCommand = "test -f /tmp/aione-workspace-ready && pgrep -x sshd >/dev/null 2>&1"
	}
	container := corev1.Container{
		Name:            "ssh",
		Image:           cfg.Image,
		ImagePullPolicy: corev1.PullIfNotPresent,
		Command:         []string{"/bin/sh", "-c"},
		Args:            []string{entrypoint},
		SecurityContext: &corev1.SecurityContext{
			RunAsUser:  &rootUser,
			RunAsGroup: &rootUser,
		},
		Ports:        containerPorts,
		Env:          envVars(cfg.Environment),
		VolumeMounts: volumeMounts,
		ReadinessProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				Exec: &corev1.ExecAction{Command: []string{"/bin/sh", "-c", readinessCommand}},
			},
			InitialDelaySeconds: 3,
			PeriodSeconds:       5,
		},
	}
	var codeDownloaderSecret *corev1.Secret
	if len(cfg.CodeRepositories) > 0 {
		secretName := resourceName + "-code-downloader"
		params := aionedownloader.Params{Codes: make([]aionedownloader.Code, 0, len(cfg.CodeRepositories))}
		downloadMounts := make([]corev1.VolumeMount, 0, len(cfg.CodeRepositories))
		for i, repo := range cfg.CodeRepositories {
			volumeName := fmt.Sprintf("code-repository-%d", i)
			volumes = append(volumes, corev1.Volume{
				Name:         volumeName,
				VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
			})
			mount := corev1.VolumeMount{Name: volumeName, MountPath: repo.MountPath}
			downloadMounts = append(downloadMounts, mount)
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
			return WorkspaceResources{}, err
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
			VolumeMounts:    downloadMounts,
		})
	}
	var datasetDownloaderSecret *corev1.Secret
	if len(cfg.Datasets) > 0 {
		secretName := resourceName + "-dataset-downloader"
		params := aionedownloader.Params{OSSDatas: make([]aionedownloader.OSSData, 0, len(cfg.Datasets))}
		downloadMounts := make([]corev1.VolumeMount, 0, len(cfg.Datasets))
		for i, dataset := range cfg.Datasets {
			volumeName := fmt.Sprintf("dataset-%d", i)
			volumes = append(volumes, corev1.Volume{
				Name:         volumeName,
				VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
			})
			mount := corev1.VolumeMount{Name: volumeName, MountPath: dataset.TargetPath}
			downloadMounts = append(downloadMounts, mount)
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
			return WorkspaceResources{}, err
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
			VolumeMounts:    downloadMounts,
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
			return WorkspaceResources{}, fmt.Errorf("invalid cloud storage size: %w", err)
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

	sts := &appsv1.StatefulSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:        resourceName,
			Namespace:   identity.Namespace,
			Labels:      labels,
			Annotations: annotations,
		},
		Spec: appsv1.StatefulSetSpec{
			Replicas:    &replicas,
			ServiceName: codeServerServiceName,
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{labelWorkspaceName: identity.Name},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels, Annotations: annotations},
				Spec: corev1.PodSpec{
					InitContainers: initContainers,
					Containers:     []corev1.Container{container},
					Volumes:        volumes,
				},
			},
		},
	}
	if cfg.ImagePullSecretName != "" {
		sts.Spec.Template.Spec.ImagePullSecrets = []corev1.LocalObjectReference{{
			Name: cfg.ImagePullSecretName,
		}}
	}
	if cfg.GPUNodeLabelKey != "" {
		sts.Spec.Template.Spec.Affinity = &corev1.Affinity{
			NodeAffinity: &corev1.NodeAffinity{
				RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{
					NodeSelectorTerms: []corev1.NodeSelectorTerm{{
						MatchExpressions: []corev1.NodeSelectorRequirement{{
							Key:      cfg.GPUNodeLabelKey,
							Operator: corev1.NodeSelectorOpExists,
						}},
					}},
				},
			},
		}
	}

	codeServerServicePort := corev1.ServicePort{
		Name:       "code-server",
		Port:       8080,
		TargetPort: intstr.FromInt(8080),
		Protocol:   corev1.ProtocolTCP,
	}
	codeServerService := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      codeServerServiceName,
			Namespace: identity.Namespace,
			Labels:    labels,
		},
		Spec: corev1.ServiceSpec{
			Type:     corev1.ServiceTypeClusterIP,
			Selector: map[string]string{labelWorkspaceName: identity.Name},
			Ports:    []corev1.ServicePort{codeServerServicePort},
		},
	}
	var sshService *corev1.Service
	if cfg.EnableSSH {
		sshServicePort := corev1.ServicePort{
			Name:       "ssh",
			Port:       22,
			TargetPort: intstr.FromInt(22),
			Protocol:   corev1.ProtocolTCP,
		}
		if cfg.NodePort != nil {
			sshServicePort.NodePort = *cfg.NodePort
		}
		sshService = &corev1.Service{
			ObjectMeta: metav1.ObjectMeta{
				Name:      sshServiceName,
				Namespace: identity.Namespace,
				Labels:    labels,
			},
			Spec: corev1.ServiceSpec{
				Type:     cfg.ServiceType,
				Selector: map[string]string{labelWorkspaceName: identity.Name},
				Ports:    []corev1.ServicePort{sshServicePort},
			},
		}
	}

	pathType := networkingv1.PathTypePrefix
	ingress := &networkingv1.Ingress{
		ObjectMeta: metav1.ObjectMeta{
			Name:      resourceName + "-code",
			Namespace: identity.Namespace,
			Labels:    labels,
		},
		Spec: networkingv1.IngressSpec{
			Rules: []networkingv1.IngressRule{{
				Host: codeServerHost(identity, cfg),
				IngressRuleValue: networkingv1.IngressRuleValue{
					HTTP: &networkingv1.HTTPIngressRuleValue{
						Paths: []networkingv1.HTTPIngressPath{{
							Path:     "/",
							PathType: &pathType,
							Backend: networkingv1.IngressBackend{
								Service: &networkingv1.IngressServiceBackend{
									Name: codeServerServiceName,
									Port: networkingv1.ServiceBackendPort{Name: "code-server"},
								},
							},
						}},
					},
				},
			}},
		},
	}

	return WorkspaceResources{
		Secret:                  secret,
		CodeDownloaderSecret:    codeDownloaderSecret,
		DatasetDownloaderSecret: datasetDownloaderSecret,
		CloudStoragePVCs:        cloudPVCs,
		StatefulSet:             sts,
		CodeServerService:       codeServerService,
		SSHService:              sshService,
		CodeServerIngress:       ingress,
	}, nil
}

func workspaceLabels(identity WorkspaceIdentity) map[string]string {
	return map[string]string{
		labelWorkspaceName: identity.Name,
		labelRunName:       identity.RunName,
		labelProject:       identity.Project,
		labelDomain:        identity.Domain,
		labelOrg:           identity.Org,
		labelActionName:    identity.ActionName,
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

func envVars(values map[string]string) []corev1.EnvVar {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	env := make([]corev1.EnvVar, 0, len(keys))
	for _, key := range keys {
		env = append(env, corev1.EnvVar{Name: key, Value: values[key]})
	}
	return env
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
		cleaned = "workspace"
	}
	if !unicode.IsLetter(rune(cleaned[0])) {
		cleaned = "ssh-" + cleaned
	}
	if len(cleaned) <= maxGeneratedNameBaseLength {
		return cleaned
	}

	hash := shortNameHash(cleaned)
	prefixLength := maxGeneratedNameBaseLength - len(hash) - 1
	return strings.TrimRight(cleaned[:prefixLength], "-") + "-" + hash
}

func codeServerHost(identity WorkspaceIdentity, cfg WorkspaceConfig) string {
	if strings.TrimSpace(cfg.CodeServerHost) != "" {
		return strings.TrimSpace(cfg.CodeServerHost)
	}
	name := identity.RunName
	if strings.TrimSpace(name) == "" {
		name = identity.Name
	}
	return kubernetesNameBase(name) + "-code." + codeServerDomain
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

func workspaceEntrypoint(enableSSH bool, sshUser string) string {
	codeServerUser := DefaultWorkspaceSSHUser
	if !enableSSH {
		return fmt.Sprintf(`set -eu
if ! id %[1]s >/dev/null 2>&1; then
  useradd -m -s /bin/bash %[1]s
fi
if command -v usermod >/dev/null 2>&1 && [ -x /bin/bash ]; then
  usermod -s /bin/bash %[1]s || true
fi
mkdir -p /home/%[1]s/.local/share/code-server
CODE_SERVER_BIN=""
if command -v code-server >/dev/null 2>&1; then
  CODE_SERVER_BIN="$(command -v code-server)"
elif [ -x /opt/code-server-4.19.0-linux-amd64/bin/code-server ]; then
  CODE_SERVER_BIN="/opt/code-server-4.19.0-linux-amd64/bin/code-server"
fi
if [ -n "$CODE_SERVER_BIN" ] && [ -x "$CODE_SERVER_BIN" ]; then
  printf 'AIONE_CODE_SERVER_STATUS %%s\n' '{"available":true}'
  touch /tmp/aione-workspace-ready
  exec su - %[1]s -c "PASSWORD='' '$CODE_SERVER_BIN' --bind-addr 0.0.0.0:8080 --auth none /home/%[1]s"
fi
printf 'AIONE_CODE_SERVER_STATUS %%s\n' '{"available":false,"reason":"CODE_SERVER_NOT_FOUND","message":"code-server is not installed in the image"}'
touch /tmp/aione-workspace-ready
while true; do sleep 3600; done
`, codeServerUser)
	}
	return fmt.Sprintf(`set -eu
if ! command -v /usr/sbin/sshd >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends openssh-server sudo ca-certificates
  fi
fi
if ! id %[1]s >/dev/null 2>&1; then
  useradd -m -s /bin/bash %[1]s
fi
if ! id %[2]s >/dev/null 2>&1; then
  useradd -m -s /bin/bash %[2]s
fi
if command -v usermod >/dev/null 2>&1 && [ -x /bin/bash ]; then
  usermod -s /bin/bash %[1]s || true
  usermod -s /bin/bash %[2]s || true
fi
mkdir -p /home/%[1]s/.ssh /home/%[2]s/.local/share/code-server /run/sshd /etc/ssh/sshd_config.d
cp /flyte-ssh/authorized_keys /home/%[1]s/.ssh/authorized_keys
chown %[1]s:%[1]s /home/%[1]s/.ssh /home/%[1]s/.ssh/authorized_keys
chmod 700 /home/%[1]s/.ssh
chmod 600 /home/%[1]s/.ssh/authorized_keys
printf 'PasswordAuthentication no\nPermitRootLogin no\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/flyte-workspace.conf
CODE_SERVER_BIN=""
if command -v code-server >/dev/null 2>&1; then
  CODE_SERVER_BIN="$(command -v code-server)"
elif [ -x /opt/code-server-4.19.0-linux-amd64/bin/code-server ]; then
  CODE_SERVER_BIN="/opt/code-server-4.19.0-linux-amd64/bin/code-server"
fi
if [ -n "$CODE_SERVER_BIN" ] && [ -x "$CODE_SERVER_BIN" ]; then
  printf 'AIONE_CODE_SERVER_STATUS %%s\n' '{"available":true}'
  su - %[2]s -c "PASSWORD='' '$CODE_SERVER_BIN' --bind-addr 0.0.0.0:8080 --auth none /home/%[2]s" &
else
  printf 'AIONE_CODE_SERVER_STATUS %%s\n' '{"available":false,"reason":"CODE_SERVER_NOT_FOUND","message":"code-server is not installed in the image"}'
fi
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -A || true
fi
touch /tmp/aione-workspace-ready
exec /usr/sbin/sshd -D -e
`, sshUser, codeServerUser)
}
