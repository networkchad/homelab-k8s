#!/bin/sh
# Does this cluster forward traffic between nodes? It is the first thing a host
# firewall kills, and the symptom is confusing: pods on some nodes cannot reach
# CoreDNS, so flux never clones the repo and nothing converges.
#
# Checked the long way round on purpose - a pod on a node with no CoreDNS replica,
# resolving a name through the kube-dns ClusterIP. Needs a running cluster.
set -eu

nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [ "$(printf '%s\n' "$nodes" | grep -c .)" -lt 2 ]; then
  echo "one node: nothing to forward, skipping"
  exit 0
fi

hosts=$(mktemp)
trap 'rm -f "$hosts"' EXIT
kubectl -n kube-system get pods -l k8s-app=kube-dns \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u >"$hosts"
target=$(printf '%s\n' "$nodes" | grep -vxF -f "$hosts" | head -1)
if [ -z "$target" ]; then
  echo "CoreDNS runs on every node: cannot prove the cross-node path"
  exit 0
fi

echo "pod on $target -> kube-dns ..."
if kubectl run homelab-preflight -n default --rm -i --restart=Never \
  --image=docker.io/busybox:1.36 --overrides="{\"spec\":{\"nodeName\":\"$target\"}}" \
  -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
  echo "ok: cross-node pod traffic and cluster DNS work"
else
  cat <<EOF
failed: pods on $target cannot reach CoreDNS.

The host is dropping forwarded traffic between the node containers. On NixOS:
  networking.firewall.forwardChainConfig = "accept";   # or "docker"
and, if nftables is enabled:
  networking.nftables.forwardChainConfig = "accept";
Docker's own rules cannot override a drop verdict in the host's forward chain.
Set it, then recreate the cluster.
EOF
  exit 1
fi
