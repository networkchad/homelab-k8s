# homelab-k8s

GitOps for the `homelab` kind cluster on a NixOS host. Flux owns everything after bootstrap.

## Bootstrap (once per cluster)

```sh
kind create cluster --config kind/cluster.yaml
kubectl config use-context kind-homelab
hack/preflight.sh          # proves the cluster can forward traffic between nodes
kubectl create -f https://github.com/fluxcd/flux2/releases/download/v2.10.1/install.yaml
kubectl apply --server-side -f clusters/homelab/flux-system/gotk-sync.yaml
```

`flux bootstrap github` works too, but this repo is public: HTTPS clone, no deploy key,
no token. Everything after the last line arrives through git. That asset is the full
bundle - seven controllers, including the image automation ones `flux install` skips.

## What runs

| area | what it gives you |
| --- | --- |
| `system/` | metrics-server — `kubectl top`, HPA |
| `cert-manager/` | cert-manager, plus a `self-signed` ClusterIssuer |
| `metallb/` | MetalLB in L2 mode, pool `172.18.0.240-250` on the kind bridge |
| `network/` | Envoy Gateway control plane, and the Gateway API CRDs it bundles |
| `edge/` | the `web` Gateway: :80 → :443, wildcard cert, MetalLB address pool, GatewayClass |
| `headlamp/` | cluster dashboard, read-only |
| `monitoring/` | kube-prometheus-stack: prometheus, alertmanager, grafana, PVCs |

Gateway API CRDs come with the Envoy Gateway chart, which bundles the upstream `v1.6.1`
set: one version, chosen by the implementation that serves them.

## Layout

`clusters/homelab/` holds flux wiring — Kustomizations and extra sources, all in the
`flux-system` namespace. Every other directory is area content and owns its namespace,
chart sources and releases. New area = one directory + one file in `clusters/homelab/`.

One rule: a custom resource never shares a directory with the HelmRelease that installs
its CRD. kustomize-controller dry-runs every document before helm-controller has run, so
such a document fails on a cold cluster and only lands minutes later on a retry. `edge/`
exists for that reason - the Certificate, the address pool and the Gateway need CRDs that
`cert-manager/`, `metallb/` and `network/` install, and get them through `dependsOn`.

## Checking a change

```sh
hack/validate.sh
```

Renders every HelmRelease with its committed values, then checks every manifest against
the CRDs that will read it - flux's, the charts' and the Gateway API bundle's. It needs
kubectl, helm, yq and kubeconform. CI runs it alongside yamllint, actionlint, shellcheck
and a guard against plaintext Secrets in a public repo.

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

## Storage

kind installs one StorageClass, `standard`: `rancher.io/local-path`,
`WaitForFirstConsumer`, `reclaimPolicy: Delete`. Nothing in this repo declares a
StorageClass or a PV; the three PVCs below are all the state there is.

| workload | size | what is lost if it goes |
| --- | --- | --- |
| prometheus | 10Gi | ≤48h of metrics history |
| alertmanager | 1Gi | silence list |
| grafana | 1Gi | dashboards and datasources you made in the UI |

Everything else rebuilds itself: cert-manager keeps certs in Secrets, Envoy Gateway
derives its config from Gateways and HTTPRoutes, headlamp holds nothing.

A local-path volume is a directory on whichever node first consumed the claim, and the PV
is pinned to that node - a pod that reschedules goes Pending rather than silently getting
an empty directory. That is why the three releases above select the node labelled
`homelab.dev/stateful`, which `kind/cluster.yaml` puts on one worker. Ask where a volume is:

```sh
kubectl get pv -o custom-columns=CLAIM:spec.claimRef.name,NODE:spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0],PATH:spec.hostPath.path
```

PVCs survive pod restarts, rollouts and node reboots. They do not survive
`kind delete cluster`, and deleting a claim deletes the data. Backups mean `docker cp` of
that directory while the pod is down.

## Worth knowing

- Public repo, so no secrets. CI fails on a plaintext `kind: Secret`. The Grafana
  password regenerates on every HelmRelease upgrade — pin `grafana.existingSecret` once a
  secrets backend exists.
- Cold start: the MetalLB pool can take one 2-minute retry while its CRDs install, and the
  Gateway stays unprogrammed until the pool exists.
- The `web` Gateway's listeners carry no hostname on purpose: a listener hostname matches
  only that exact host, so `homelab.test` would never serve `grafana.homelab.test`. Each
  route names its own host and may live in its own namespace, provided that namespace
  carries `homelab.dev/gateway: web`.
- etcd / kube-scheduler / kube-controller-manager monitors are off: they bind `127.0.0.1`
  inside kind nodes and can never be scraped.
- kube-prometheus-stack installs its CRDs but Helm never upgrades them — set
  `crds.upgradeJob.enabled: true` or apply them by hand when bumping the chart. Same for
  the Gateway API bundle Envoy Gateway ships.
- kindnet is the CNI: routes and masquerade only, no NetworkPolicy enforcement.
- Host needs docker and cgroup v2: `virtualisation.docker.enable = true;` and
  `boot.kernelModules = [ "br_netfilter" "overlay" ];`. It also has to forward traffic
  between the node containers, which NixOS's firewall refuses by default - run
  `hack/preflight.sh` after `kind create` and it names the option to set.

## Pins

flux v2.10.1 · kind node v1.35.0 · Envoy Gateway v1.10.0 (Gateway API v1.6.1) ·
cert-manager v1.21.3 · MetalLB 0.16.2 · kube-prometheus-stack 93.6.0 ·
headlamp 0.46.0 · metrics-server 3.14.0

## Later

Secrets backend (sops / sealed-secrets / external-secrets) then ACME DNS01, alertmanager
receivers, real auth in front of Headlamp, backups.
