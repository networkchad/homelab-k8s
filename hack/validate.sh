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
mkdir -p "$out/values" "$out/schemas" "$out/flux-schemas"

# q: one query over a multi-doc stream. yq answers documents the filter dropped
# with nothing at all, or a bare ---, and either would poison a [ "$x" = y ]
# test, so both go.
q() { "$YQ" -r "$1" "$2" | grep -vE '^(---)?[[:space:]]*$' || true; }

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

  q 'select(.kind == "HelmRepository" and .spec.type != "oci") | .metadata.name + " " + .spec.url' "$built" |
    while read -r name url; do helm repo add "$name" "$url" >/dev/null; done

  for name in $(q 'select(.kind == "HelmRelease") | .metadata.name' "$built"); do
    sel='select(.kind == "HelmRelease" and .metadata.name == "'"$name"'")'
    ns=$(q "$sel | .metadata.namespace" "$built")
    src=$(q "$sel | .spec.chart.spec.sourceRef.name" "$built")
    chart=$(q "$sel | .spec.chart.spec.chart" "$built")
    version=$(q "$sel | .spec.chart.spec.version" "$built")
    hs='select(.kind == "HelmRepository" and .metadata.name == "'"$src"'")'
    url=$(q "$hs | .spec.url" "$built")
    if [ "$(q "$hs | .spec.type // \"\"" "$built")" = oci ]; then
      ref=$url/$chart # helm has no notion of an oci "repository"
    else
      ref=$src/$chart
    fi

    values=$out/values/$name.yaml
    # Exactly one document matches, so the --- separators yq leaves behind for the
    # dropped ones are noise; helm would read the first of them as the values file.
    "$YQ" -o=yaml "$sel | .spec.values" "$built" | grep -v '^---$' >"$values" || :
    [ -s "$values" ] || echo '{}' >"$values"

    if helm template "$name" "$ref" --version "$version" --namespace "$ns" \
      --values "$values" >"$out/$name.out" 2>"$out/$name.err"; then
      printf 'render  %-22s %-44s %3s docs\n' "$name" "$ref@$version" "$(grep -c '^kind: ' "$out/$name.out")"
    else
      printf 'render  %-22s FAILED %s@%s\n' "$name" "$ref" "$version"
      tail -5 "$out/$name.err"
      exit 1
    fi
  done
done

# Shape checks, most accurate source first.
#
# 1. The schemas flux ships with its release are generated from its own CRDs with
#    additionalProperties: false, so a field flux has never heard of fails here.
#    That matters: the api server prunes or rejects unknown fields, and a field
#    that is quietly dropped (spec.pruning instead of spec.prune) turns garbage
#    collection off without a sound.
curl -sSfL -o "$out/flux-schemas.tgz" \
  "https://github.com/fluxcd/flux2/releases/download/$FLUX_VERSION/crd-schemas.tar.gz"
tar xzf "$out/flux-schemas.tgz" -C "$out/flux-schemas"

# 2. For other kinds, take the CRDs the cluster actually gets - the ones the charts
#    render plus the Gateway API bundle Envoy Gateway installs. These check types
#    and required fields; they cannot flag unknown fields, because a CRD schema
#    does not say "no other fields", and kubeconform's -strict only reads what the
#    schema states. The api server is still the real test.
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
for chart_out in "$out"/*.out; do gen_schemas "$chart_out"; done
curl -sSfL -o "$out/gateway-api.yaml" \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml"
gen_schemas "$out/gateway-api.yaml"

# 3. Core kinds from kubeconform's own registry, which does publish -strict schemas.
# kubeconform's -schema-location is a template, not a directory.
"$KUBECONFORM" -strict -summary -ignore-missing-schemas \
  -schema-location "$out/flux-schemas/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -schema-location "$out/schemas/{{ .Group }}-{{ .ResourceKind }}-{{ .ResourceAPIVersion }}.json" \
  -schema-location default "$out/all.yaml"
