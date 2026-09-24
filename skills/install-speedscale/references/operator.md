# Operator reference: Helm chart values, platforms, GitOps, upgrades

Use the `KUBE_CONTEXT` selected in `SKILL.md` for every Helm and kubectl command that touches a cluster. Pass `--kube-context "$KUBE_CONTEXT"` to Helm and `--context="$KUBE_CONTEXT"` to kubectl.

Read this during Phase 4 of SKILL.md when picking values for a specific
platform, when the user cannot run Helm against the cluster, or when
upgrading. The chart is `speedscale/speedscale-operator` from
`https://speedscale.github.io/operator-helm/` (source:
https://github.com/speedscale/operator-helm). Full values reference:
https://docs.speedscale.com/reference/helm/.

## Contents

1. What the chart creates and in what order
2. Required and commonly set values
3. Platform blocks (EKS, GKE, AKS, minikube, kind, k3s, OpenShift, Istio/Calico)
4. eBPF capture
5. Private registries and air-gapped clusters
6. GitOps: Argo CD, Flux, rendered manifests
7. Upgrades and CRDs
8. Uninstall

## 1. What the chart creates and in what order

Helm owns: the `trafficreplays.speedscale.com` CRD, operator ServiceAccount +
ClusterRole/Binding, operator ConfigMap, Mutating + Validating webhook
configurations, operator Service and Deployment, and (if `ebpf.enabled`) the
`nettap` DaemonSet with its RBAC.

Pre-install hooks (Jobs) run first: create the API-key Secret when `apiKey`
is given, create TLS + webhook cert Secrets, validate the API key against the
cloud (`speedctl init` inside the job, with in-pod retry), and build the Java
truststore Secret when `createJKS` is true. A hook failure stops Helm before
any operator resource is applied, which is why a failed install leaves only
the namespace and a Job behind.

The operator, once running, registers the cluster with the tenant and then
creates the runtime components itself: `speedscale-forwarder`,
`speedscale-inspector`, and per-replay generator/responder/redis. A green
Helm release therefore does not mean the forwarder is up yet; that is what
`scripts/verify.sh` and `speedctl check operator` are for.

Requirements: Kubernetes 1.19+ (chart declares `>= 1.17`, speedctl's check
enforces 1.19), Helm 3 or 4, outbound HTTPS from the cluster to
`app.speedscale.com` and the tenant's S3 bucket, and the API server able to
reach the operator webhook on 443. Networking detail:
https://docs.speedscale.com/reference/networking/.

## 2. Required and commonly set values

| Value | Default | Notes |
| --- | --- | --- |
| `apiKey` / `apiKeySecret` | `""` / `""` | One is required. Prefer `apiKeySecret` (Secret with keys `SPEEDSCALE_API_KEY`, `SPEEDSCALE_APP_URL`) |
| `clusterName` | `my-cluster` | Always set. Shown in the dashboard; `[a-z0-9-]`, <= 63 chars |
| `appUrl` | `app.speedscale.com` | Must match the CLI context's host (`scripts/apikey.sh --app-url`); BYOC, on-prem, and Speedscale-internal dev tenants differ |
| `cloudProvider` | `""` | `aws`, `gcp`, `azure`. Currently only `aws` changes behaviour (Fargate exclusion for nettap) |
| `deployDemo` | `"java"` | `""` on production clusters |
| `ebpf.enabled` | `false` | Recommended `true` when nodes qualify (section 4) |
| `namespaceSelector` | `[]` | Restrict the operator (and nettap) to listed namespaces; the `speedscale` namespace is added automatically |
| `dlp.enabled` | `false` | Redact before egress; set when the user mentions PII/compliance |
| `image.pullSecrets` | `[]` | Needed in the install namespace and every captured namespace when images are mirrored |
| `hostNetwork` | `false` | Only when the control plane cannot reach pod IPs (EKS + Calico) |
| `createJKS` | `true` | Set `false` if the JKS pre-install job is unwanted or Java images are blocked |
| `dashboardAccess` | `true` | Deploys the inspector so the dashboard and `speedctl infra` can act on the cluster |
| `tolerations` | arch NoSchedule for amd64/arm64 | Extend for tainted node pools |

Confirm values before applying, without secrets:

```bash
helm show values speedscale/speedscale-operator > speedscale-default-values.yaml
helm template speedscale-operator speedscale/speedscale-operator -n speedscale -f speedscale-values.yaml | less
```

## 3. Platform blocks

Append the matching block to `speedscale-values.yaml`. Provider detection:
the preflight prints the API server URL and node labels; `eks.amazonaws.com`
labels or `*.eks.amazonaws.com` server -> EKS, `cloud.google.com/gke-*` ->
GKE, `kubernetes.azure.com` -> AKS, context `minikube`/`kind-*`/`k3d-*` ->
local.

**EKS (EC2 nodes)**

```yaml
cloudProvider: aws
```

**EKS with Fargate profiles**: keep `cloudProvider: aws` (excludes Fargate
from nettap) and remember Fargate pods cannot run eBPF or privileged init
containers; capture there needs sidecars with `privilegedSidecars: false`.

**EKS with Calico CNI**: the API server cannot reach pod IPs, so the webhook
must be on the host network:

```yaml
cloudProvider: aws
hostNetwork: true
```

**GKE Standard**

```yaml
cloudProvider: gcp
```

**GKE Autopilot**: Autopilot rejects containers that set CPU/memory but not
ephemeral-storage, and rejects unknown node-affinity keys (which is why
`cloudProvider` must stay `""` or `gcp`, never `aws`).

```yaml
cloudProvider: gcp
ensureMinimumEphemeralStorage: true
```

eBPF on Autopilot depends on the cluster's allowed capabilities; try it, and
fall back to `ebpf.enabled: false` if the DaemonSet is rejected by the warden.

**AKS**

```yaml
cloudProvider: azure
```

**minikube**: start it with CNI enabled or webhooks time out:

```bash
minikube start --cni=true --container-runtime=containerd
```

Clock drift on the VM causes `SignatureDoesNotMatch: Signature expired`
errors from the pre-install job; `minikube ssh -- sudo date -s "$(date -u)"`
or restart the VM. eBPF works on the default minikube kernel on x86_64;
on Apple Silicon check `uname -r` inside the node (needs 6.0+).

**kind / k3d / k3s / Docker Desktop**: no special values. eBPF requires the
node (container) kernel to be the host kernel with BTF; Docker Desktop on
macOS qualifies on recent releases, otherwise set `ebpf.enabled: false`.

**microk8s**: `microk8s enable dns` before installing, or webhooks fail.

**OpenShift**: the default `globalPodSecurityContext` (non-root UID 2100,
drop ALL, RuntimeDefault seccomp) is designed for restricted SCCs. If the
namespace's SCC assigns a UID range, remove `runAsUser`/`runAsGroup` from
`globalPodSecurityContext` and `fsGroup` from `globalSecurityContext` so the
platform assigns them. eBPF nettap needs a privileged-ish SCC bound to its
ServiceAccount (`BPF`, `PERFMON`, `NET_ADMIN`, `SYS_ADMIN`, `SYS_PTRACE`,
`SYS_RESOURCE` capabilities plus hostPath). Tell the user this is a cluster-
admin decision. Detailed page:
https://docs.speedscale.com/getting-started/installation/install/ (OpenShift tab).

**Istio / Linkerd**: no install-time change. Capture in a mesh uses eBPF (sees
plaintext before Envoy) or the "dual proxy" sidecar mode; mention that the
operator needs permission to create Istio `Sidecar` resources, which the
chart's ClusterRole already includes.

**Tainted or dedicated node pools**: extend `tolerations` and
`nodeSelector`; the operator, forwarder, and inspector are small (see
`operator.resources`, `forwarder.resources`, `inspector.resources`).

## 4. eBPF capture

Recommended default for Kubernetes: no sidecars, no app changes, sees
plaintext for TLS via uprobes/JVM agent. Node requirements: Linux kernel
5.15+ on x86_64, 6.0+ on arm64, BTF enabled (`/sys/kernel/btf/vmlinux`
present), and host access to `/proc`, `/sys/fs/cgroup`, kernel BTF paths.
The preflight prints kernel version and arch per node so you can decide.

```yaml
ebpf:
  enabled: true
  configuration:
    capture:
      # optional: restrict which namespaces nettap watches (defaults to all,
      # or to namespaceSelector when that is set)
      namespaces: []
      # optional static targets; most users annotate workloads instead
      targets: []
      #  - name: my-service
      #    namespaces: [my-namespace]
      #    podSelector:
      #      matchLabels:
      #        app: my-service
```

Per-workload opt-in after install (the usual path):

```bash
kubectl -n my-namespace annotate deployment my-app capture.speedscale.com/enabled="true"
```

Verify: `kubectl -n speedscale get daemonset speedscale-nettap` shows READY ==
DESIRED, and `kubectl -n speedscale logs daemonset/speedscale-nettap | grep "probe attached"`.
Nodes that fail the kernel check simply do not run the probe; the DaemonSet
pod on them will crash-loop with a BTF/kernel message. Either exclude those
nodes with `ebpf.nettap` affinity or accept sidecar capture for workloads
there. Reference: https://docs.speedscale.com/reference/ebpf-traffic-collection/.

## 5. Private registries and air-gapped clusters

Images live under `gcr.io/speedscale` (`image.registry`), tag
`image.tag` (= chart `appVersion`), plus `imageTags.nettap`. To mirror:

```yaml
image:
  registry: registry.example.com/speedscale
  pullSecrets:
    - name: speedscale-regcred
jks:
  image: registry.example.com/amazoncorretto:23   # or createJKS: false
replayComponents:
  redis:
    image: registry.example.com/redis:7
```

Pull secrets must exist in `speedscale` and in every namespace that will run
captured workloads or replays. Egress to `app.speedscale.com` (443) is still
required unless the tenant is BYOC; there is no fully offline mode.

## 6. GitOps: Argo CD, Flux, rendered manifests

Helm does not have to run in the cluster. Render once, commit, and let the
GitOps engine apply:

```bash
helm template speedscale-operator speedscale/speedscale-operator \
  -n speedscale --create-namespace -f speedscale-values.yaml > speedscale-operator.yaml
```

Caveat: rendered YAML contains the hook Jobs but nothing enforces hook
ordering, so a plain `kubectl apply` may start the operator before the
validation job has run. Argo CD honours Helm hooks when given the chart
directly, which is the better path:

```yaml
project: default
source:
  repoURL: https://speedscale.github.io/operator-helm/
  chart: speedscale-operator
  targetRevision: <chart version from `helm search repo speedscale`>
  helm:
    values: |
      apiKeySecret: speedscale-apikey
      clusterName: <name>
destination:
  namespace: speedscale
  name: in-cluster
syncPolicy:
  automated: {}
  syncOptions:
    - CreateNamespace=true
```

Create the `speedscale-apikey` Secret out of band (SealedSecrets, ESO, SOPS)
so the key never enters git. Flux: a `HelmRepository` + `HelmRelease` with the
same values works and also runs hooks. Rendered-manifest lifecycle notes:
https://docs.speedscale.com/reference/helm/#rendered-manifests-and-gitops.

## 7. Upgrades and CRDs

Reuse the values the release was installed with. When no values file exists,
recover them without printing the key and keep `clusterName` exactly as it
is (a new name registers a new cluster):

```bash
helm --kube-context "$KUBE_CONTEXT" -n speedscale get values speedscale-operator -o json | jq 'del(.apiKey)' > speedscale-values.yaml
```

```bash
helm repo update speedscale
helm search repo speedscale/speedscale-operator            # see target version
helm --kube-context "$KUBE_CONTEXT" -n speedscale upgrade speedscale-operator speedscale/speedscale-operator -f speedscale-values.yaml --wait
kubectl --context="$KUBE_CONTEXT" -n <captured-namespace> rollout restart deployment  # pick up new sidecar/agent
```

Helm 3 never upgrades CRDs. After a chart upgrade, apply the CRD from the new
chart explicitly when release notes call for it:

```bash
helm pull speedscale/speedscale-operator --untar --untardir /tmp/ss-chart
kubectl --context="$KUBE_CONTEXT" apply -f /tmp/ss-chart/speedscale-operator/templates/crds/
```

A major chart version bump (2.x -> 3.0) signals a breaking change with
manual steps in the release notes; read them before upgrading. Keep one
values file per cluster in git so every upgrade reuses the same inputs.
Sidecar-captured workloads must be restarted to get the new proxy; eBPF
captured ones do not.

## 8. Uninstall

```bash
helm --kube-context "$KUBE_CONTEXT" -n speedscale uninstall speedscale-operator
```

Helm leaves the TrafficReplay CRD and its resources in place. For a full purge, first list `kubectl --context="$KUBE_CONTEXT" get trafficreplays.speedscale.com -A`, confirm the user wants those resources removed, then delete the CRD with the same context. `speedctl uninstall --force` also removes replay resources and needs the same confirmation.

If someone already deleted the namespace by hand and deployments across the cluster now fail with `failed calling webhook "operator.speedscale.com"`, remove the webhooks manually (see troubleshooting) before anything else.
