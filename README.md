# homelab-k8s

GitOps for the `homelab` kind cluster on a NixOS host. After bootstrap, flux owns the cluster and nothing is applied by hand.

## Bootstrap (once)

```sh
kind create cluster --config kind/cluster.yaml
kubectl config use-context kind-homelab
flux install --components=source-controller,kustomize-controller,helm-controller   # nix run nixpkgs#flux
kubectl apply --server-side -f clusters/homelab/flux-system/gotk-sync.yaml          # point flux at this repo
```

Push to `main` and it reconciles; `flux reconcile kustomization flux-system` if you're impatient.

## Layout

```
kind/cluster.yaml               cluster shape — the one non-gitops part
clusters/homelab/               flux entrypoints, one file per area
  flux-system/gotk-sync.yaml    repo self-reference
  monitoring.yaml               -> ./monitoring
monitoring/                     namespace, HelmRepository, HelmReleases
```

New area = new top-level directory + one Kustomization in `clusters/homelab/`.

## Grafana

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-grafana 3000:80
kubectl -n monitoring get secret kube-prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

## Worth knowing

- Public repo, so no secrets. Grafana's admin password is chart-generated and changes on every HelmRelease upgrade — pin it when SOPS / sealed-secrets / external-secrets lands.
- etcd, kube-scheduler and kube-controller-manager monitors are off: they bind `127.0.0.1` inside kind nodes and can never be scraped from pod network.
- kind's `standard` StorageClass is a hostPath inside the node containers. PVCs survive pod restarts, not `kind delete cluster`.
- CRDs come from the chart's `crds` subchart: Helm installs them but never upgrades them. Apply by hand on a major bump, or set `crds.upgradeJob.enabled: true`.
- Host needs docker, cgroup v2, and forwarding accepted:

  ```nix
  virtualisation.docker.enable = true;
  boot.kernelModules = [ "br_netfilter" "overlay" ];
  networking.nftables.forwardChainConfig = "accept";
  ```

## Later

Secrets backend, ingress, alertmanager receivers, cert-manager if anything needs TLS.
