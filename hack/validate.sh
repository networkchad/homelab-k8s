#!/bin/sh
# Everything that can be checked without a cluster:
#   1. every HelmRelease renders with its committed values
#   2. every manifest matches the CRD it will be read by
# Needs kubectl, helm, yq, kubeconform.
set -eu

# Keep in step with the bootstrap URL in README.md.
FLUX_VERSION=${FLUX_VERSION:-v2.10.1}
YQ=${YQ:-yq}
KUBECONFORM=${KUBECONFORM:-kubeconform}

# shellcheck disable=SC1007  # CDPATH= is a prefix assignment, not an assignment
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${TMPDIR:-/tmp}/homelab-validate.$$
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/values" "$out/schemas"

# q: yq emits a --- for every document a filter dropped; shells hate that.
q() { "$YQ" -r "$1" "$2" | grep -v '^---$' || true; }

# Areas come from the flux wiring, so this list cannot drift from it.
kubectl kustomize "$root/clusters/homelab" >"$out/wiring.yaml"
areas="clusters/homelab"
for p in $(q 'select(.kind == "Kustomization" and .metadata.name != "flux-system") | .spec.path' "$out/wiring.yaml"); do
  areas="$areas $(echo "$p" | sed 's|^\./||')"
done

for d in $areas; do
  built=$out/$(basename "$d").yaml
  kubectl kustomize "$root/$d" >"$built"
  cat "$built" >>"$out/all.yaml"
  echo '---' >>"$out/all.yaml"

  q 'select(.kind == "HelmRepository") | .metadata.name + " " + .spec.url' "$built" |
    while read -r name url; do helm repo add "$name" "$url" >/dev/null; done

  for name in $(q 'select(.kind == "HelmRelease") | .metadata.name' "$built"); do
    sel='select(.kind == "HelmRelease" and .metadata.name == "'"$name"'")'
    chart=$(q "$sel | .spec.chart.spec.chart // \"\"" "$built")
    if [ -n "$chart" ]; then
      ref=$(q "$sel | .spec.chart.spec.sourceRef.name + \"/\" + .spec.chart.spec.chart" "$built")
      version=$(q "$sel | .spec.chart.spec.version" "$built")
    else # chartRef -> the tag the OCIRepository pins is the chart version
      src=$(q "$sel | .spec.chart.spec.chartRef.name" "$built")
      oci='select(.kind == "OCIRepository" and .metadata.name == "'"$src"'")'
      ref=$(q "$oci | .spec.url" "$built")
      version=$(q "$oci | .spec.ref.tag" "$built")
    fi
    values=$out/values/$name.yaml
    # Exactly one document matches, so the --- separators yq leaves behind for the
    # dropped ones are noise; helm would read the first of them as the values file.
    "$YQ" -o=yaml "$sel | .spec.values" "$built" | grep -v '^---$' >"$values" || :
    [ -s "$values" ] || echo '{}' >"$values"

    if helm template "$name" "$ref" --version "$version" --namespace monitoring \
      --values "$values" >"$out/$name.out" 2>"$out/$name.err"; then
      printf 'render  %-22s %-44s %3s docs\n' "$name" "$ref@$version" "$(grep -c '^kind: ' "$out/$name.out")"
    else
      printf 'render  %-22s FAILED %s@%s\n' "$name" "$ref" "$version"
      tail -5 "$out/$name.err"
      exit 1
    fi
  done
done

# Structural checks for hand-written manifests. Schemas come out of the CRDs the
# cluster actually gets: flux's own install, the CRDs the charts render, and the
# Gateway API bundle Envoy Gateway v1.10.0 installs. A field the CRD does not have
# fails here instead of at reconcile time.
gen_schemas() { # $1 = file holding CustomResourceDefinition documents
  f=$1
  for crd in $(q 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$f"); do
    sel='select(.kind == "CustomResourceDefinition" and .metadata.name == "'"$crd"'")'
    # shellcheck disable=SC2046  # two fields, no spaces: splitting is the point
    set -- $(q "$sel | .spec.group + \" \" + (.spec.names.kind | downcase)" "$f")
    group=$1
    kind=$2
    for v in $(q "$sel | .spec.versions[].name" "$f"); do
      "$YQ" -o=json "$sel | .spec.versions[] | select(.name == \"$v\") | .schema.openAPIV3Schema" \
        "$f" >"$out/schemas/$group-$kind-$v.json"
    done
  done
}

[ -n "${FLUX_MANIFESTS:-}" ] || {
  FLUX_MANIFESTS=$out/flux-install.yaml
  curl -sSfL -o "$FLUX_MANIFESTS" \
    "https://github.com/fluxcd/flux2/releases/download/$FLUX_VERSION/install.yaml"
}
gen_schemas "$FLUX_MANIFESTS"

for chart_out in "$out"/*.out; do gen_schemas "$chart_out"; done

curl -sSfL -o "$out/gateway-api.yaml" \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml"
gen_schemas "$out/gateway-api.yaml"

# kubeconform's -schema-location is a template, not a directory.
"$KUBECONFORM" -strict -summary -ignore-missing-schemas \
  -schema-location "$out/schemas/{{ .Group }}-{{ .ResourceKind }}-{{ .ResourceAPIVersion }}.json" \
  -schema-location default "$out/all.yaml"
