# homelab-k8s

GitOps for the `homelab` kind cluster. Five commands bootstrap it; flux owns everything after
that.

What is here has been run: Authelia signs people in, the Gateway's `extAuth` answers for Headlamp
and Grafana, and fluent-bit's logs reach Loki. The one thing that has not had a week to prove
itself is retention.

## Bootstrap

```sh
kind create cluster --config kind/cluster.yaml
kubectl config use-context kind-homelab
kubectl create -f https://github.com/fluxcd/flux2/releases/download/v2.10.1/install.yaml
kubectl create secret generic sops-age -n flux-system --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
kubectl apply --server-side -f clusters/homelab/flux-system/gotk-sync.yaml
```

The host has to pass traffic between the node containers: forwarding on, `br_netfilter` and
`overlay` loaded (a running docker daemon does both), and reverse-path filtering loose. That
last one is the quiet failure: pod traffic is sourced from the pod CIDR, which the host has no
route to, so strict `rp_filter` drops cross-node pod traffic and nothing else, and the cluster
looks broken rather than the host. NixOS: `networking.firewall.checkReversePath = "loose";`.

`install.yaml` is the full bundle, image automation controllers included; `flux bootstrap
github` works too, since a public repo needs no deploy key over HTTPS.

The `sops-age` secret is the one thing flux is not told through git, because it is the key that
unlocks what is in git: without it the two areas carrying secrets stall on a decryption error
and everything else comes up normally. The key's name inside the secret has to end in `.agekey`
- that is how kustomize-controller recognises it - and the command above uses `$HOME` rather
than `~` because bash does not expand a tilde that follows an `=`.

## The age key

`~/.config/sops/age/keys.txt` is in no repo and cannot be recovered from this one: it is the
private half of the keypair that every `secrets.yaml` is encrypted to, and sops reads it from
exactly that path without being told. On a host that has never done this:

```sh
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt   # creates it 0600, refuses to overwrite one
age-keygen -y ~/.config/sops/age/keys.txt   # the public half - what .sops.yaml has to name
```

A second or rebuilt host copies that file rather than generating its own: committed ciphertext
opens only for the recipient `.sops.yaml` lists, so a new pair decrypts nothing until every file
is re-encrypted to it. Losing it loses the secrets, `git log` included.

## Secrets

Committed as sops ciphertext and decrypted on the way in by kustomize-controller
(`spec.decryption` on the two Kustomizations that have it), so the repo stays public and
`git diff` still shows which key changed:

```sh
sops monitoring/secrets.yaml                  # edit, and it re-encrypts on save
sops --encrypt --in-place auth/secrets.yaml   # only if the file was decrypted by hand
```

`.sops.yaml` matches any `secrets.yaml` and encrypts only `data` and `stringData`, so comments
and metadata stay readable. Rotating the key: `age-keygen` a pair, add the new recipient to
`.sops.yaml`, `sops updatekeys` each file, replace the `sops-age` secret.

sops and age because the controller that reads the files already decrypts. Vault is a stateful
service that has to be unsealed before anything can start; sops-operator and external-secrets
add CRDs and a loop keeping two copies of every secret in step.

## What runs

| directory | what it gives you |
| --- | --- |
| `platform/` | metrics-server, cert-manager, MetalLB, Envoy Gateway |
| `gateway/` | self-signed issuer, MetalLB pool, one `web` Gateway: :80 → :443, wildcard cert |
| `auth/` | Authelia: the one place a password is typed, and the gate in front of the rest |
| `logging/` | fluent-bit on every node, Loki holding a week of what it finds, read in Grafana |
| `headlamp/` | cluster dashboard, read-only, behind Authelia |
| `monitoring/` | prometheus, alertmanager, grafana, and their PVCs |

`clusters/homelab/` is flux wiring; every other directory is an area that owns its namespaces,
chart sources and releases. One rule shapes the layout: a custom resource never shares a
directory with the chart that installs its CRD, because kustomize-controller dry-runs every
document before helm-controller has run. `gateway/` exists for that reason.

CI builds every area, renders every chart with the values committed for it, checks every
document against the CRD schemas of the controllers that read it, runs Authelia's own
`config validate`, and adds yamllint, actionlint and a check that no Secret holds anything but
ciphertext.

## Reaching it

```sh
kubectl -n web get gateway web
```

The `EXTERNAL-IP` comes from MetalLB; point `/etc/hosts` at it:

```
172.18.0.240 homelab.internal auth.homelab.internal headlamp.homelab.internal grafana.homelab.internal
```

`.internal` is private-use and reserved from delegation, so nothing on the public internet can
answer for it. Only `.local` would be a mistake - that one is mDNS.

- `https://auth.homelab.internal` — `anon`, whose password is in the notes made when the secrets
  were generated and in nothing else: only its argon2 hash is in git.
- `https://headlamp.homelab.internal` — the Gateway asks Authelia on every request; Headlamp
  shows the cluster through its own read-only service account.
- `https://grafana.homelab.internal` — past the same gate, then Grafana's own `admin` and the
  password in `monitoring/secrets.yaml`. Two passwords is the price of not running an identity
  provider; what it buys is that Grafana works while Authelia does not.

Prometheus and Alertmanager get no route on purpose, so `kubectl port-forward` them, and the
certificates are self-signed, so import the `web-tls` secret's CA or click through.

## Accounts

One account lives in `auth/users.yaml`, as an argon2 hash rather than a password:

```sh
docker run --rm authelia/authelia:4.39.24 authelia crypto hash generate argon2 \
  --password "$(openssl rand -base64 24 | tr -d '=+/')" --no-confirm
```

Append the block, append the hash, push. Authelia watches that file, so a new user needs no
restart - unlike `auth/configuration.yaml`, which is only read at startup:
`kubectl rollout restart deployment/authelia -n authelia`.

Groups are what policy is written against, so `admins` is what an `access_control` rule matches
on: one factor everywhere, TOTP enrolment offered from the first sign-in, and a rule per host can
raise the bar to two without touching a client.

## Retention and storage

Seven days in the two places that keep history: prometheus' `retention: 7d` under an 8GB ceiling,
and Loki's `retention_period: 168h` with its compactor deleting what is older. The ceilings are
what keep a full disk from being how a week of history ends.

Nothing here declares a StorageClass: kind installs the only one the cluster has, `standard` →
`rancher.io/local-path`, `WaitForFirstConsumer`, `reclaimPolicy: Delete`. Five claims are all
the state there is:

| claim | size | what is lost if it goes |
| --- | --- | --- |
| `prometheus-…-prometheus-db-…` | 10Gi | ≤7d of metric history |
| `alertmanager-…-alertmanager-db-…` | 1Gi | the silence list |
| `kube-prometheus-stack-grafana` | 1Gi | dashboards and datasources made in the UI |
| `loki-data-loki-0` | 10Gi | ≤7d of logs |
| `authelia` | 100Mi | sessions, TOTP and passkey enrolments |

Everything else rebuilds itself: certificates live in Secrets, Envoy Gateway derives its data
plane from the Gateway and HTTPRoutes, and users and config come from git.

A local-path volume is a directory on whichever node first consumed the claim and the PV carries
a nodeAffinity for it, so a rescheduled pod goes Pending rather than silently getting an empty
directory. That is why the five stateful pods select `homelab.internal/stateful`, which
`kind/cluster.yaml` puts on one worker; fluent-bit is the exception on purpose, since a DaemonSet
that tails `/var/log/containers` has to be everywhere.

```sh
kubectl get pv -o custom-columns=CLAIM:spec.claimRef.name,\
NODE:spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0],\
PATH:spec.hostPath.path
```

Paths look like `/var/local-path-provisioner/pvc-<uuid>_monitoring_<claim>` *inside* the node
container, so a backup is `docker cp homelab-worker:<path>` with the pod stopped. PVCs survive
pod restarts, rollouts and reboots; they do not survive `kind delete cluster`.

## Why these

- **Loki, not Elastic.** Seven days of container logs cost about 300MiB of RAM here and about 3GiB
  with one Elasticsearch node, which is most of what a three-node kind cluster has. Retention is
  one value read from git rather than an ILM policy POSTed after the cluster exists, and the logs
  land in the Grafana that is already running.
- **Authelia, not Keycloak.** One container and a sqlite file, against a JVM and a postgres it
  needs in order to say hello. One password, TOTP and "is this request from someone who has logged
  in" is all that is asked of it, and the admin UI and protocol breadth that justify Keycloak buy
  nothing here.
- **extAuth, not OIDC.** The Gateway asks Authelia on every request, in the protocol Envoy's
  ext_authz speaks. Nothing here needs to know *who* is asking: Headlamp uses its own read-only
  service account whoever is looking, and Grafana has its own users. So there is no client,
  redirect URI, client secret or signing key, and one secret less that can leak. The price is
  that Grafana asks for its own password too.

## Upgrades and gotchas

- Not every CRD is upgraded by bumping a chart: cert-manager and MetalLB ship theirs as templates,
  but Envoy Gateway, kube-prometheus-stack, Loki and Authelia put theirs in `crds/`, which Helm
  applies once. kube-prometheus-stack re-applies its own through the `crds.upgradeJob` hook; the
  other three are a `kubectl apply --server-side` at the bump.
- A chart's values schema rejects a field it has never heard of; a CRD schema does not - the API
  server prunes unknown fields, so a typo in a `SecurityPolicy` is silently a policy without that
  block. CI renders the charts; reading the Gateway API docs after a bump is on you.
- Renaming or merging an area makes flux prune the old Kustomization, and pruning
  garbage-collects the HelmReleases it created, so a running release can be uninstalled while the
  new area re-adopts it. Better done on an empty cluster.
- Gateway listeners carry no hostname on purpose: a listener hostname matches only that exact
  host, so `homelab.internal` would never serve `grafana.homelab.internal`. Each route names its
  own hosts and may live in any namespace labelled `homelab.internal/gateway: web`.
- kindnet is the CNI: routes and masquerade, no NetworkPolicy enforcement. Envoy Gateway runs its
  data plane in `envoy-gateway-system`; `web` holds the Gateway, its certificate and the :80
  redirect, which has to be that listener's only route.

## Pins

| thing | pinned |
| --- | --- |
| flux | v2.10.1 |
| kind node image | v1.35.0 |
| Envoy Gateway | v1.10.0 (Gateway API v1.6.1) |
| cert-manager | v1.21.3 |
| MetalLB | 0.16.2 |
| metrics-server | 3.14.0 |
| Authelia | chart 0.11.22 · app 4.39.24 |
| kube-prometheus-stack | 93.6.0 |
| Loki | chart 7.7.0 |
| fluent-bit | chart 0.58.3 |
| headlamp | chart 0.46.0 |
| CI tools | kubeconform v0.8.0 · yq v4.44.3 · yamllint 1.38.0 · actionlint 1.7.12 |
| host tools | sops 3.13.3 · age 1.3.2 |

## Later

ACME DNS01, alertmanager receivers, volume backups. Grafana's second password is fixable without
an identity provider - `extAuth.http.headersToBackend` can copy Authelia's answer into the
upstream request, which is what Grafana's `auth.proxy` reads - but that trusts a header instead of
a signature and only pays off once more than one app wants it.
