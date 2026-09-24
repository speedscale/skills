# Troubleshooting

Match the symptom, apply the fix, re-run `scripts/verify.sh`. Do not
reinstall in a loop; every entry here explains the cause so you can confirm
it before acting.

## Contents

1. Permissions needed to install
2. CLI: command not found, wrong version, two copies
3. Authentication: init, tenant, non-interactive
4. Helm: pre-install job failed
5. Operator: pods not ready, self-check failed, certificate errors
6. Webhooks: cluster refuses deployments after a bad uninstall
7. Networking: egress, proxies, private clusters
8. eBPF: nettap crash-looping or not capturing
9. Local clusters: minikube, microk8s, kind, Docker Desktop
10. Where to escalate

## 1. Permissions needed to install

`speedctl check operator --pre` verifies these read-only on a fresh cluster
(it fails on purpose when the `speedscale` namespace already exists; use
`speedctl check operator` without `--pre` there). Create rights are
required for:

- cluster-scoped: `CustomResourceDefinition`, `ClusterRole`,
  `ClusterRoleBinding`, `MutatingWebhookConfiguration`,
  `ValidatingWebhookConfiguration`
- namespaced (in `speedscale`): `ConfigMap`, `Deployment`, `Job`, `Role`,
  `RoleBinding`, `Service`, `Secret`, `ServiceAccount`, `DaemonSet` (eBPF)

`kubectl auth can-i create clusterrole` returning `no` means the user needs a
cluster admin to run the Helm step, or to render manifests for them (GitOps
section of operator.md). After install, the `speedscale-operator` ClusterRole
holds get/list/watch/patch on workloads across namespaces (or only those in
`namespaceSelector`); security reviewers can inspect it with
`kubectl get clusterrole speedscale-operator -o yaml`.

## 2. CLI: command not found, wrong version, two copies

- `speedctl: command not found` right after the script: `~/.speedscale` is
  not on `PATH`. `export PATH="$PATH:$HOME/.speedscale"` now, and append the
  same line to the user's rc file.
- Version does not change after upgrade: `which -a speedctl` shows two
  installs (brew + script). Remove the unintended one.
- `There is no speedctl support for Windows without WSL`: expected; use WSL
  or, for proxymock only, the native `.exe`.
- `Failed to find checksum binary`: install `openssl` or `perl`'s `shasum`.
- `The checksum was different`: a proxy or CDN returned a partial/altered
  download. Retry; if it persists, download the binary and `.sha256`
  manually from https://downloads.speedscale.com/ and compare.
- macOS Gatekeeper "cannot be opened because the developer cannot be
  verified": binaries are signed and notarized; this appears only if the
  file was downloaded through a browser. Re-run the script or
  `xattr -d com.apple.quarantine ~/.speedscale/speedctl`.

## 3. Authentication: init, tenant, non-interactive

- Browser flow never completes from the agent shell: it needs a human. Ask
  the user to run `proxymock init` in their own terminal.
- `speedctl check` fails with 401/403: the key may be revoked or from another tenant. Rotate it at https://app.speedscale.com/profile, then have the user run `proxymock init --overwrite` in their terminal. In CI, update the secret and run `speedctl check` with a clean Speedscale home so environment-based registration writes a fresh config.
- Non-interactive registration rejected: environment-based registration requires proxymock Pro or an Enterprise tenant. Free users do the browser flow once.
- Wrong tenant: `speedctl check` prints the tenant name; compare with the
  user's expectation before installing the operator. Switch with
  `speedctl config use-context <name>`.
- Empty tenant after corporate-email sign-in: the email domain is not mapped;
  ask support@speedscale.com or Slack.

## 4. Helm: pre-install job failed

```
Error: INSTALLATION FAILED: failed pre-install: job failed: BackoffLimitExceeded
```

Read the job log first:

```bash
kubectl -n speedscale get jobs
kubectl -n speedscale logs job/speedscale-operator-pre-install
```

Typical log lines and causes:

| Log says | Cause | Fix |
| --- | --- | --- |
| `401`, `invalid api key`, `tenant not found` | wrong key / tenant, Secret keys misnamed | Secret must have `SPEEDSCALE_API_KEY` and `SPEEDSCALE_APP_URL`; recreate it |
| `dial tcp ... i/o timeout` to app.speedscale.com | egress blocked, NetworkPolicy, proxy needed | open egress or set `http_proxy`/`https_proxy`/`no_proxy` values |
| `SignatureDoesNotMatch: Signature expired` | node clock skew (minikube, VMs) | sync the clock, retry |
| `OOMKilled` / no log at all | pre-install job memory | raise `preInstall.resources.limits.memory` |
| image pull errors | private registry / no pull secret | `image.registry`, `image.pullSecrets` |
| JKS/keytool errors | Java image blocked or restricted UID | `createJKS: false` or `jks.image` with a compliant image |

Then clean up and retry. A failed hook leaves the Job behind and Helm will
refuse to re-run until it is gone:

```bash
helm -n speedscale uninstall speedscale-operator
kubectl -n speedscale delete job speedscale-operator-pre-install
```

`--timeout` too short for slow image pulls looks like a hook failure too;
use `--wait --timeout 10m`.

## 5. Operator: pods not ready, self-check failed, certificate errors

Check in this order:

```bash
kubectl -n speedscale get pods
kubectl -n speedscale describe pod -l app=speedscale-operator | tail -30
kubectl -n speedscale logs deploy/speedscale-operator --tail=100
```

- `"M":"self-check failed, exiting"` with `could not verify cert:
  crypto/rsa: verification error`: leftover cert Secrets or webhook configs
  from an earlier install. Full clean and reinstall:
  ```bash
  helm -n speedscale uninstall speedscale-operator
  kubectl delete mutatingwebhookconfigurations speedscale-operator speedscale-operator-replay --ignore-not-found
  kubectl delete validatingwebhookconfiguration speedscale-operator speedscale-operator-replay --ignore-not-found
  ```
  Check for other resources in the `speedscale` namespace before deleting it; the certificate problem does not require namespace deletion. Then re-run Phase 4 from the Secret step.
- Operator Running but forwarder/inspector never appear: registration with
  the cloud failed. Logs show the HTTP error; usually egress or tenant.
- `Pending` pods: tolerations/nodeSelector do not match any node, or
  resource requests exceed a small local cluster. `kubectl describe pod`
  shows the scheduler message.
- Fine on Helm, `speedctl check operator` red on "Speedscale control plane
  health": give it 60-90 seconds after the operator starts; the forwarder is
  created by the operator, not by Helm.

## 6. Webhooks: cluster refuses deployments after a bad uninstall

Symptom anywhere in the cluster:

```
Internal error occurred: failed calling webhook "operator.speedscale.com":
Post "https://speedscale-operator.speedscale.svc:443/mutate?timeout=30s": ... connection refused
```

Cause: the `speedscale` namespace or operator Deployment was deleted while
the webhook configurations remained. Fix immediately (this blocks every
deployment in the cluster):

```bash
kubectl delete mutatingwebhookconfigurations speedscale-operator speedscale-operator-replay --ignore-not-found
kubectl delete validatingwebhookconfiguration speedscale-operator speedscale-operator-replay --ignore-not-found
```

Then run `speedctl uninstall --force` to finish the cleanup properly. If a
`TrafficReplay` cannot be edited or deleted (finalizer stuck), the
validating webhook `speedscale-operator` is the one to remove.

## 7. Networking: egress, proxies, private clusters

- Cluster components need HTTPS to `app.speedscale.com` and to the tenant's
  S3 bucket/stream endpoints. Full list:
  https://docs.speedscale.com/reference/networking/.
- Corporate proxy: set `http_proxy`, `https_proxy`, `no_proxy` values; they
  become env vars on every Speedscale pod. Include the cluster CIDRs and
  `.svc` in `no_proxy`.
- Webhook path: the API server must reach the operator Service on 443. On
  private GKE clusters open the master-authorized firewall rule for 443 to
  the node pool; on EKS + Calico use `hostNetwork: true`.
- NetworkPolicy default-deny namespaces: allow egress from `speedscale` to
  the internet and ingress from the API server to the operator pod.
- Laptop side: `speedctl`/`proxymock` need HTTPS to `app.speedscale.com` and
  `downloads.speedscale.com`; they honour `HTTPS_PROXY`.

## 8. eBPF: nettap crash-looping or not capturing

- CrashLoop with messages about BTF or kernel version: node does not meet
  the baseline (x86_64 5.15+, arm64 6.0+, BTF). Either exclude the node pool
  or set `ebpf.enabled: false` and use sidecars.
- DaemonSet rejected by an admission controller (GKE Autopilot warden,
  Gatekeeper, Kyverno, PSA `restricted`): nettap needs `hostPath`, added
  capabilities, and `allowPrivilegeEscalation: true`. Label the namespace
  `pod-security.kubernetes.io/enforce=privileged` or obtain an exemption.
- The DaemonSet is named `speedscale-nettap`; `kubectl -n speedscale get ds`
  with no such row means `ebpf.enabled` is false in the release values.
- Running but no traffic for a workload: the workload is not annotated
  (`capture.speedscale.com/enabled="true"`) and not in a static target, or
  the port is in `ignore-ports`. Check with `proxymock cluster capture
  status` or the MCP `cluster` tool's `capture-status`.
- TLS traffic appears encrypted: language/library not in the supported
  uprobe matrix (Go 1.18+, OpenSSL, rustls 0.23, JVM via agent). See
  https://docs.speedscale.com/reference/ebpf-traffic-collection/.

## 9. Local clusters

- minikube webhook timeouts: start with `--cni=true
  --container-runtime=containerd`.
- minikube `Signature expired`: VM clock drift; resync or restart.
- microk8s webhook errors: `microk8s enable dns`.
- kind/k3d: fine; eBPF depends on the host kernel. Docker Desktop on macOS
  provides a Linux VM kernel; recent versions (6.x) work, older do not.
- Resource pressure: local clusters with 2 CPUs struggle with the default
  requests once a replay starts (generator/responder). Lower
  `replayComponents.*.resources` or give the VM more CPU.

## 10. Where to escalate

- Community Slack: https://slack.speedscale.com
- Support: support@speedscale.com (include `speedctl check operator`
  output, `helm -n speedscale status speedscale-operator`, and operator
  logs; strip API keys)
- Docs: https://docs.speedscale.com/getting-started/installation/install/troubleshooting/
