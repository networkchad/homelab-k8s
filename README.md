# homelab-k8s

GitOps for the `homelab` kind cluster on a NixOS host. Four commands bootstrap it; flux
owns everything after that.

## Bootstrap

```sh
kind create cluster --config kind/cluster.yaml
kubectl config use-context kind-homelab
kubectl create -f https://github.com/fluxcd/flux2/releases/download/v2.10.1/install.yaml
kubectl apply --server-side -f clusters/homelab/flux-system/gotk-sync.yaml
```

The host has to forward traffic between the node containers, which NixOS's firewall
refuses by default and docker's rules cannot override: `virtualisation.docker.enable =
true;`, `boot.kernelModules = [ "br_netfilter" "overlay" ];`, and
`networking.firewall.forwardChainConfig = "accept";` (plus
`networking.nftables.forwardChainConfig = "accept";` if nftables is on). Get this wrong
and pods on some nodes never reach CoreDNS, so flux never clones the repo.

That `install.yaml` is the full bundle - seven controllers, including the image
automation ones `flux install` skips. `flux bootstrap github` works too; the repo is
public, so HTTPS needs no deploy key.

## What runs

| directory | what it gives you |
| --- | --- |
| `platform/` | metrics-server, cert-manager, MetalLB, Envoy Gateway |
| `gateway/` | self-signed issuer, MetalLB pool, one `web` Gateway: :80 → :443, wildcard cert |
| `headlamp/` | cluster dashboard, read-only |
| `monitoring/` | prometheus, alertmanager, grafana, and their PVCs |

`clusters/homelab/` is flux wiring; every other directory is an area that owns its
namespaces, chart sources and releases.

One rule shapes the layout: a custom resource never shares a directory with the chart
that installs its CRD, because kustomize-controller dry-runs every document before
helm-controller has run — on a cold cluster such a document fails and only lands on a
later retry. `gateway/` exists for that reason: its Certificate, address pool,
GatewayClass and Gateway get `platform/`'s CRDs through `dependsOn` instead of a race.

CI builds every area and checks every document against the CRD schemas of the controllers
that read it, plus yamllint, actionlint and a guard against plaintext Secrets in a public
repo.

## Reaching it

```sh
kubectl -n web get gateway web
```

The `EXTERNAL-IP` comes from MetalLB. Point `/etc/hosts` at it:

```
172.18.0.240 homelab.internal headlamp.homelab.internal grafana.homelab.internal
```

`homelab.internal` is private-use space: it is not delegated, so nothing on the public
internet can answer for it, and ICANN has reserved `.internal` from new-TLD delegation so
nobody can take it later. Only `.local` would be a mistake - that one is mDNS.

- `https://headlamp.homelab.internal` — token: `kubectl -n headlamp create token headlamp`
- `https://grafana.homelab.internal` — `admin`, password from:

```sh
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

Prometheus and Alertmanager get no route on purpose: `kubectl port-forward` them.
Certificates are self-signed, so import the `web-tls` secret's CA or click through.

## Storage

Nothing here declares a StorageClass or a PV. kind installs the only one the cluster has:
`standard` → `rancher.io/local-path`, `WaitForFirstConsumer`, `reclaimPolicy: Delete`.
Three PVCs, and that is all the state there is:

| claim | size | what is lost if it goes |
| --- | --- | --- |
| `prometheus-…-prometheus-db-…` | 10Gi | ≤48h of metric history |
| `alertmanager-…-alertmanager-db-…` | 1Gi | the silence list |
| `kube-prometheus-stack-grafana` | 1Gi | dashboards and datasources made in the UI |

Everything else rebuilds itself: cert-manager keeps certificates in Secrets, Envoy
Gateway derives its data plane from the Gateway and HTTPRoutes, headlamp holds nothing.

A local-path volume is a directory on whichever node first consumed the claim, and the PV
carries a nodeAffinity for it, so a rescheduled pod goes Pending rather than silently
getting an empty directory. That is why prometheus, alertmanager and grafana select the
node labelled `homelab.internal/stateful`, which `kind/cluster.yaml` puts on one worker.
Ask where a volume actually lives:

```sh
kubectl get pv -o custom-columns=CLAIM:spec.claimRef.name,\
NODE:spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0],\
PATH:spec.hostPath.path
```

Paths look like `/var/local-path-provisioner/pvc-<uuid>_monitoring_<claim>` *inside* the
node container, so a backup is `docker cp homelab-worker:<path>` with the pod stopped.
PVCs survive pod restarts, rollouts and reboots; they do not survive `kind delete
cluster`, and deleting a claim deletes the data.

## Worth knowing

- Renaming or merging an area makes flux prune the old Kustomization, and pruning
  garbage-collects the HelmReleases it created - so a running release can be uninstalled
  while the new area re-adopts it. Expect churn on the commit that moves things: that is
  the one change better made on an empty cluster.
- Public repo, so no secrets in git: CI fails on a plaintext `kind: Secret`. The Grafana
  admin password is chart-generated and lives in a Secret; once a secrets backend exists,
  point `grafana.existingSecret` at something real rather than reading it back out.
- cert-manager and MetalLB ship their CRDs as chart templates, so bumping those releases
  upgrades the CRDs. Envoy Gateway (with the Gateway API v1.6.1 bundle) and
  kube-prometheus-stack put theirs in `crds/`, which Helm creates once and never updates:
  apply the new ones by hand when you bump those, or set
  `crds.upgradeJob.enabled: true` on kube-prometheus-stack (preview).
- Gateway listeners carry no hostname on purpose: a listener hostname matches only that
  exact host, so `homelab.internal` would never serve `grafana.homelab.internal`. Each
  route names its own hosts and may live in any namespace labelled
  `homelab.internal/gateway: web`.
- etcd, kube-scheduler and kube-controller-manager monitors are off: they bind
  `127.0.0.1` inside kind nodes and can never be scraped.
- kindnet is the CNI: routes and masquerade, no NetworkPolicy enforcement.
- Envoy Gateway runs the data plane in `envoy-gateway-system`; `web` holds the Gateway,
  its certificate and the :80 redirect, which has to be that listener's only route.

## Pins

flux v2.10.1 · kind node v1.35.0 · Envoy Gateway v1.10.0 (Gateway API v1.6.1) ·
cert-manager v1.21.3 · MetalLB 0.16.2 · kube-prometheus-stack 93.6.0 · headlamp 0.46.0 ·
metrics-server 3.14.0

## Later

Secrets backend (sops, sealed-secrets or external-secrets), then ACME DNS01, alertmanager
receivers, real auth in front of Headlamp, volume backups.
