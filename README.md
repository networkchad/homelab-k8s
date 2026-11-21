# homelab-k8s

GitOps for the `homelab` kind cluster. Five commands bootstrap it; flux owns
everything after that.

## Bootstrap

```sh
kind create cluster --config kind/cluster.yaml
kubectl config use-context kind-homelab
kubectl create -f https://github.com/fluxcd/flux2/releases/download/v2.10.1/install.yaml
kubectl create secret generic sops-age -n flux-system --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
kubectl apply --server-side -f clusters/homelab/flux-system/gotk-sync.yaml
```

The host has to pass traffic between the node containers: forwarding on, `br_netfilter` and
`overlay` loaded (a running docker daemon arranges both), and nothing between the nodes
dropping what they send each other. The quiet one is reverse-path filtering: pod traffic is
sourced from the pod CIDR, which the host has no route to, so a host that refuses packets whose
source it cannot route back to drops that traffic and nothing else - which looks like a broken
cluster rather than a broken host. See *Worth knowing*.

That `install.yaml` is the full bundle - seven controllers, including the image automation
ones `flux install` skips. `flux bootstrap github` works too; the repo is public, so HTTPS
needs no deploy key.

The `sops-age` secret is the one thing flux is not told through git, because it is the key
that unlocks what is in git: without it the two areas that carry secrets stall with a
decryption error and everything else comes up normally. The key's name inside the secret has
to end in `.agekey` - that is how kustomize-controller recognises an age key. `$HOME` and not
`~` above is also not style: bash does not expand a tilde that follows an `=`, so kubectl goes
looking for a file literally named `~/.config/...`.

## Secrets

Secrets are committed as sops ciphertext and decrypted on the way in by
kustomize-controller (`spec.decryption` on the two Kustomizations that have them), so the
repo can stay public and `git diff` still shows which key changed:

```sh
sops monitoring/secrets.yaml                     # edit, and it re-encrypts on save
sops --encrypt --in-place auth/secrets.yaml      # only if the file was decrypted by hand
```

`.sops.yaml` says which files are encrypted (any `secrets.yaml`) and to which age key; only
`data` and `stringData` values are encrypted, so comments and metadata stay readable. The
private half of that key lives on the host and in the `sops-age` secret and nowhere else, so
rotating it means: `age-keygen` a new pair, add the new recipient to `.sops.yaml`,
`sops updatekeys <file>` each one, and replace the `sops-age` secret.

sops and age because the decrypting was already in the controller that reads the files. The
alternatives all cost more than the problem: Vault is a stateful service that has to be
unsealed before anything can start, sops-operator or external-secrets add CRDs and a sync
loop to keep two copies of each secret in step.

## What runs

| directory | what it gives you |
| --- | --- |
| `platform/` | metrics-server, cert-manager, MetalLB, Envoy Gateway |
| `gateway/` | self-signed issuer, MetalLB pool, one `web` Gateway: :80 → :443, wildcard cert |
| `auth/` | Authelia: the one place a password is typed, and the gate in front of the rest |
| `logging/` | fluent-bit on every node, Loki holding a week of what it finds |
| `headlamp/` | cluster dashboard, read-only, behind Authelia |
| `monitoring/` | prometheus, alertmanager, grafana, and their PVCs |
| `gpu/` | the host's GPU on one worker, as `nvidia.com/gpu`, with its metrics in Grafana |

`clusters/homelab/` is flux wiring; every other directory is an area that owns its
namespaces, chart sources and releases.

One rule shapes the layout: a custom resource never shares a directory with the chart that
installs its CRD, because kustomize-controller dry-runs every document before
helm-controller has run - on a cold cluster such a document fails and only lands on a later
retry. `gateway/` exists for that reason: its Certificate, address pool, GatewayClass and
Gateway get `platform/`'s CRDs through `dependsOn` instead of a race.

CI builds every area, renders every chart with the values committed for it, checks every
document against the CRD schemas of the controllers that read it, runs Authelia's own
`config validate` over Authelia's own config, and adds yamllint, actionlint and a check that no
Secret holds anything but ciphertext.

## Reaching it

```sh
kubectl -n web get gateway web
```

The `EXTERNAL-IP` comes from MetalLB. Point `/etc/hosts` at it:

```
172.18.0.240 homelab.internal auth.homelab.internal headlamp.homelab.internal grafana.homelab.internal
```

`homelab.internal` is private-use space: it is not delegated, so nothing on the public
internet can answer for it, and ICANN has reserved `.internal` from new-TLD delegation so
nobody can take it later. Only `.local` would be a mistake - that one is mDNS.

- `https://auth.homelab.internal` — `anon`, whose password is in the notes made when the
  secrets were generated and in nothing else: only its argon2 hash is in git.
- `https://headlamp.homelab.internal` — the Gateway asks Authelia on every request; Headlamp
  itself shows the cluster through its own read-only service account.
- `https://grafana.homelab.internal` — past the same Authelia gate, then Grafana's own
  `admin` and the password in `monitoring/secrets.yaml`. Two passwords for Grafana is the
  cost of not running an identity provider; what it buys is that Grafana works while
  Authelia does not, which is when you need it.

Prometheus and Alertmanager get no route on purpose: `kubectl port-forward` them.
Certificates are self-signed, so import the `web-tls` secret's CA or click through.

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090
```

## Accounts

One account lives in `auth/users.yaml`, as an argon2 hash rather than a password:

```sh
docker run --rm authelia/authelia:4.39.24 authelia crypto hash generate argon2 \
  --password "$(openssl rand -base64 24 | tr -d '=+/')" --no-confirm
```

Append the block, append the hash, push. Authelia watches that file, so a new user needs no
restart - unlike `auth/configuration.yaml`, which is only read at startup:

```sh
kubectl rollout restart deployment/authelia -n authelia
```

Groups are what policy is written against, so `admins` in that file is what an
`access_control` rule matches on: one factor is required everywhere, TOTP enrolment is
offered from the first sign-in, and a rule per host can raise the bar to two without
touching any client. Grafana's own admin is the `admin-user` in its Secret, not a group.

## Retention and storage

Seven days, in the two places that keep history: prometheus' `retention: 7d` with an 8GB
ceiling, and Loki's `retention_period: 168h` with its compactor deleting what is older. The
ceilings are what keep a full disk from being the way that a week of history ends.

Nothing here declares a StorageClass or a PV. kind installs the only one the cluster has:
`standard` → `rancher.io/local-path`, `WaitForFirstConsumer`, `reclaimPolicy: Delete`. Five
claims, and that is all the state there is:

| claim | size | what is lost if it goes |
| --- | --- | --- |
| `prometheus-…-prometheus-db-…` | 10Gi | ≤7d of metric history |
| `alertmanager-…-alertmanager-db-…` | 1Gi | the silence list |
| `kube-prometheus-stack-grafana` | 1Gi | dashboards and datasources made in the UI |
| `loki-data-loki-0` | 10Gi | ≤7d of logs |
| `authelia` | 100Mi | sessions, TOTP and passkey enrolments |

Everything else rebuilds itself: cert-manager keeps certificates in Secrets, Envoy Gateway
derives its data plane from the Gateway and HTTPRoutes, headlamp and Loki hold nothing else,
and Authelia's users and config come from git.

A local-path volume is a directory on whichever node first consumed the claim, and the PV
carries a nodeAffinity for it, so a rescheduled pod goes Pending rather than silently
getting an empty directory. That is why the five stateful pods select the node labelled
`homelab.internal/stateful`, which `kind/cluster.yaml` puts on one worker. Fluent-bit is the
exception on purpose: a DaemonSet that tails `/var/log/containers` has to be on every node.
Ask where a volume actually lives:

```sh
kubectl get pv -o custom-columns=CLAIM:spec.claimRef.name,\
NODE:spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0],\
PATH:spec.hostPath.path
```

Paths look like `/var/local-path-provisioner/pvc-<uuid>_monitoring_<claim>` *inside* the
node container, so a backup is `docker cp homelab-worker:<path>` with the pod stopped.
PVCs survive pod restarts, rollouts and reboots; they do not survive `kind delete cluster`,
and deleting a claim deletes the data.

## Why these

- **Loki, not Elastic.** The same question - seven days of container logs, read somewhere -
  costs about 300MiB of RAM with Loki and fluent-bit, and about 3GiB with ECK and one
  Elasticsearch node, which is most of what a four-node kind cluster has. Retention is one
  config value that is read from git, not an ILM policy POSTed to an API after the cluster
  exists, and the logs end up in the Grafana that is already running rather than in a second
  UI to log in to.
- **Authelia, not Keycloak.** One stateless-ish container with a sqlite file, against a JVM
  and a postgres it needs in order to say hello. What is asked of it here is one password,
  TOTP and an answer to "is this request from someone who has logged in", and Authelia does
  all three; the admin UI, realm export and protocol breadth that justify Keycloak buy
  nothing here.
- **Envoy Gateway stays.** It was already the ingress, and `SecurityPolicy` has `oidc`,
  `extAuth`, `jwt` and `authorization` in it, so nothing had to be added to get a login in
  front of a route.
- **extAuth, not OIDC.** Authelia is asked on every request whether the browser carries a
  session, in the protocol Envoy's ext_authz speaks, and the browser is sent to Authelia when
  the answer is no. Nothing here needs to know *who* is asking: Headlamp shows the cluster as
  its own read-only service account whoever is looking, and Grafana has its own users and
  roles. So there is no client, no redirect URI, no client secret and no signing key, and one
  password less that can leak. The price is that Grafana asks for its own password too.
  OIDC would also have needed Authelia to derive its issuer from each request, which it
  cannot do for a token call made inside the cluster: the session cookie rules only match the
  public URL, so Grafana's server-to-server call failed with `no session cookie configuration
  matches url 'https://10.96.34.183:9091'` however the request was written.

## Worth knowing

- **Reverse-path filtering on the host drops cross-node pod traffic, and looks like a broken
  cluster** - this cluster's first bootstrap stalled as a DNS timeout in flux. A pod on a
  worker reaches CoreDNS on the control-plane with a pod-CIDR source address; the host has no
  route to the pod CIDR, so a host that refuses packets it cannot route back to kills exactly
  that traffic. Pod-to-node and node-to-node are sourced from addresses the host does route, so
  everything else stays healthy, and `iptables -L FORWARD` looks clean because the drop is in
  `mangle PREROUTING`. Read every table, not just `filter`, and check the counters while a probe
  is in flight - a catch-all `DROP` that climbs is the culprit:

  ```sh
  kubectl run dnscheck --image=docker.io/library/busybox:1.36 --restart=Never \
    --overrides='{"spec":{"nodeName":"homelab-worker"}}' --command -- \
    nslookup kubernetes.default.svc.cluster.local
  kubectl logs dnscheck && kubectl delete pod dnscheck    # "no servers could be reached"
  ```

  Fix it on the host, not in git: relax the test to loose, which still refuses sources that are
  unroutable altogether. NixOS `networking.firewall.checkReversePath = "loose";`, otherwise
  `net.ipv4.conf.all.rp_filter = 2` or the firewall's equivalent. Adding host routes for the pod
  CIDRs works too and goes stale the moment kind picks a different range.

- Renaming or merging an area makes flux prune the old Kustomization, and pruning
  garbage-collects the HelmReleases it created - so a running release can be uninstalled
  while the new area re-adopts it. Expect churn on the commit that moves things: that is the
  one change better made on an empty cluster.
- A chart's values schema catches a field it has never heard of; a CRD schema does not - the
  API server prunes unknown fields instead of refusing them, so a typo in a `SecurityPolicy`
  is silently a policy without that block. That asymmetry is why CI renders the charts and
  why the Gateway API documents are worth a read-through after a bump.
- The Authelia chart's values schema predates 4.39 and cannot express the session cookie
  field 4.39 requires, so `auth/configuration.yaml` is Authelia's own file, mounted in as a
  ConfigMap, and the chart is used only to install and upgrade. Its secret keys arrive as
  files: Authelia reads a `*_FILE` variable in place of the matching config key, so the
  ConfigMap itself only ever holds digests.
- Loki and Authelia each keep one file on one node, so both select `homelab.internal/stateful`
  and both recreate rather than roll: a second pod could not open the same volume.
- cert-manager and MetalLB ship their CRDs as chart templates, so bumping those releases
  upgrades the CRDs. Envoy Gateway (with the Gateway API v1.6.1 bundle),
  kube-prometheus-stack, Loki and Authelia put theirs in `crds/`, which Helm creates once and
  never updates: apply the new ones by hand when you bump those, or set
  `crds.upgradeJob.enabled: true` on kube-prometheus-stack (preview).
- Gateway listeners carry no hostname on purpose: a listener hostname matches only that exact
  host, so `homelab.internal` would never serve `grafana.homelab.internal`. Each route names
  its own hosts and may live in any namespace labelled `homelab.internal/gateway: web`.
- etcd, kube-scheduler and kube-controller-manager monitors are off: they bind `127.0.0.1`
  inside kind nodes and can never be scraped.
- kindnet is the CNI: routes and masquerade, no NetworkPolicy enforcement.
- Envoy Gateway runs the data plane in `envoy-gateway-system`; `web` holds the Gateway, its
  certificate and the :80 redirect, which has to be that listener's only route.
- **The GPU reaches a pod by mount, not by runtime.** kind cannot ask docker for a GPU - no
  `--gpus`, no `--device`, no runtime - and nothing else fills the gap either. The nvidia runtime
  is what turns `NVIDIA_VISIBLE_DEVICES` into devices and libraries, and it is not here; CDI
  would, but this kubelet hands containerd no CDI devices at all (a pod annotated
  `cdi.k8s.io/gpu: nvidia.com/gpu=0` arrives as `Config.CDIDevices: []`), and the device plugin's
  own CDI mode has to *write* a spec, which it can only do by looking `libcuda.so.<version>` up
  in `/driver-root/etc/ld.so.cache` - a file NixOS does not have. So the pod carries what the
  runtime would have injected: privileged is what gets it the host's `/dev/nvidia*`, and the
  driver is these two mounts plus the path, because `/run/opengl-driver/lib` is symlinks into
  the store and an empty linker cache is not going to resolve anything for it.

  ```yaml
  containers:
    - name: cuda
      securityContext: {privileged: true}
      resources: {limits: {nvidia.com/gpu: 1}}
      env: [{name: LD_LIBRARY_PATH, value: /run/opengl-driver/lib}]
      volumeMounts:
        - {name: driver, mountPath: /run/opengl-driver, readOnly: true}
        - {name: store, mountPath: /nix/store, readOnly: true}
  volumes:
    - {name: driver, hostPath: {path: /run/opengl-driver}}
    - {name: store, hostPath: {path: /nix/store}}
  ```

  The CUDA `vectorAdd` sample passes on `homelab-worker2` with exactly that. Note what is *not*
  in it: a store hash. The driver's own path is a symlink a driver bump repoints, but a node
  already running holds the old one, so recreate the GPU worker after a bump and `nix gc` can
  have what is left.

- One GPU, three privileged nodes: **nothing enforces which one uses it**. Every kind node is
  a privileged container and already sees `/dev/nvidia0`, so `gpu/` makes the GPU schedulable
  on one node and no more - a privileged pod anywhere can open the device, and the boilerplate
  above asks for `privileged` because that is the cheapest way to get the device nodes. And it
  is your desktop's GPU: the 4GiB is shared with X, so what a pod gets is what the compositor
  leaves. `gpu/` also runs the exporter that reads the same card through NVML - DCGM is not an
  option, the NixOS driver package does not ship it - whose metrics land in the GPU dashboard
  that monitoring/'s Grafana sidecar provisions next to them.

## Not yet proven

Everything above is checked offline - built, rendered, schema-validated, and for Authelia
started for real in docker, where it signs people in and publishes its keys. Four things
need the cluster and are worth watching on the first boot: Envoy's `extAuth` call to
Authelia for Headlamp, which is a protocol handshake no offline check can make; fluent-bit
finding the container logs through kind's mount layout; Grafana mapping `admins` to its own
admin role from the token's groups; and Loki's compactor actually deleting on the seventh
day rather than on the eighth.

The GPU is off this list: the plugin counting the card, a CUDA sample passing on the GPU
worker and the exporter answering a scrape are all things this cluster has now done.

The one to read the logs for is the second half of the third: Grafana verifies the ID token
it gets, including its `iss`, and Authelia derives that from the Host of the request that
mints it. Token, userinfo and jwks are the in-cluster service URLs so that both sides of the
comparison see the same issuer; if Grafana ever logs an issuer mismatch, that pairing is the
dial, and `validate_id_token: false` is the blunt one.

## Pins

flux v2.10.1 · kind node v1.35.0 · Envoy Gateway v1.10.0 (Gateway API v1.6.1) ·
cert-manager v1.21.3 · MetalLB 0.16.2 · Authelia chart 0.11.22 (Authelia 4.39.24) ·
kube-prometheus-stack 93.6.0 · Loki 7.7.0 · fluent-bit 0.58.3 · headlamp 0.46.0 ·
metrics-server 3.14.0 · nvidia-device-plugin v0.20.1 · nvidia_gpu_exporter 2.0.0 ·
CI: kubeconform v0.8.0, yq v4.44.3, yamllint 1.38.0, actionlint 1.7.12 ·
sops 3.13.3 and age 1.3.2 on the host

## Later

ACME DNS01, alertmanager receivers, volume backups. Grafana's second password is fixable
without an identity provider - `extAuth.http.headersToBackend` can copy Authelia's answer
into the upstream request, which is what Grafana's `auth.proxy` reads - but that trusts a
header instead of a signature and only pays off once more than one app wants it.
