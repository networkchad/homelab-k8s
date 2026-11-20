# homelab-k8s

GitOps for the `homelab` kind cluster on a NixOS host. Flux owns everything after bootstrap.

## Bootstrap (once per cluster)

```sh
kind create cluster --config kind/cluster.yaml
kubectl config use-context kind-homelab
kubectl create -f https://github.com/fluxcd/flux2/releases/download/v2.10.1/install.yaml
kubectl apply --server-side -f clusters/homelab/flux-system/gotk-sync.yaml
```

`flux bootstrap github` works too, but this repo is public: HTTPS clone, no deploy key,
no token. Everything after the last line arrives through git.

## What runs

| area | what it gives you |
| --- | --- |
| `system/` | metrics-server — `kubectl top`, HPA |
| `cert-manager/` | cert-manager, plus a `self-signed` ClusterIssuer |
| `metallb/` | MetalLB in L2 mode, pool `172.18.0.240-250` on the kind bridge |
| `network/` | Gateway API, NGINX Gateway Fabric, one `web` Gateway: :80 → :443, wildcard cert |
| `headlamp/` | cluster dashboard, read-only |
| `monitoring/` | kube-prometheus-stack: prometheus, alertmanager, grafana, PVCs |

Gateway API CRDs are pulled from upstream (tag `v1.7.0`) instead of a chart: NGINX
Gateway Fabric ships only its own CRDs, and pinning the channel keeps that visible.

## Layout

`clusters/homelab/` holds flux wiring — Kustomizations and extra sources, all in the
`flux-system` namespace. Every other directory is area content and owns its namespace,
chart sources and releases. New area = one directory + one file in `clusters/homelab/`.

## Reaching it

```sh
kubectl -n web get svc                       # EXTERNAL-IP is from the MetalLB pool
```

Point `/etc/hosts` at it, then:

```
172.18.0.240 homelab.test headlamp.homelab.test grafana.homelab.test
```

- `https://headlamp.homelab.test` — token: `kubectl -n headlamp create token headlamp`
- `https://grafana.homelab.test` — admin, password below (chart-generated)

```sh
kubectl -n monitoring get secret kube-prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

Certs come from the self-signed issuer, so import the `web-tls` CA into your browser or
click through the warning.

## Worth knowing

- Public repo, so no secrets. CI fails on a plaintext `kind: Secret`. The Grafana
  password regenerates on every HelmRelease upgrade — pin `grafana.existingSecret` once a
  secrets backend exists.
- Cold start: the MetalLB pool can take one 2-minute retry while its CRDs install, and the
  Gateway stays unprogrammed until the pool exists.
- kind's `standard` StorageClass is a hostPath inside the node container. PVCs survive pod
  restarts, not `kind delete cluster`.
- etcd / kube-scheduler / kube-controller-manager monitors are off: they bind `127.0.0.1`
  inside kind nodes and can never be scraped.
- kube-prometheus-stack installs its CRDs but Helm never upgrades them — set
  `crds.upgradeJob.enabled: true` or apply them by hand when bumping the chart.
- Host needs docker, cgroup v2 and forwarding accepted:
  `virtualisation.docker.enable = true;` `boot.kernelModules = [ "br_netfilter" "overlay" ];`
  `networking.nftables.forwardChainConfig = "accept";`

## Pins

flux v2.10.1 · kind node v1.35.0 · gateway-api v1.7.0 · cert-manager v1.21.3 ·
NGINX Gateway Fabric 2.9.0 · MetalLB 0.16.2 · kube-prometheus-stack 93.6.0 ·
headlamp 0.46.0 · metrics-server 3.14.0

## Later

Secrets backend (sops / sealed-secrets / external-secrets) then ACME DNS01, alertmanager
receivers, real auth in front of Headlamp, backups.
