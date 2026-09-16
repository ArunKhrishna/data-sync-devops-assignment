# data-sync

Kubernetes deployment for the data-sync FastAPI service, delivered as a Helm chart with a
Kustomize production overlay, plus an Ansible role for the VM path.

## Repository layout

```text
.
├── README.md                       # this file
├── DESIGN.md                       # scaling, isolation, secret rotation
├── Makefile                        # make validate runs all static checks
├── docs/
│   ├── DECISIONS.md                # options considered and trade-offs
│   └── ARCHITECTURE.md             # architecture, NFRs, maintaining the repo
├── scripts/
│   └── verify-kustomize.sh         # builds the overlay and checks the key fields
├── helm/charts/data-sync/          # Helm chart
├── standard/data-sync/
│   ├── base/                       # chart rendered by kustomize
│   └── production/                 # production overlay
├── ansible/                        # Ansible role, playbook, group_vars
└── test/
    ├── stub-app/                   # tiny FastAPI app for Minikube only
    └── minikube/                   # Minikube values and test Redis
```

The assignment's `playbooks/` and `group_vars/` paths live under `ansible/`
(`ansible/playbooks/`, `ansible/group_vars/`), so ansible-lint and `ansible-playbook` only
see one root.

## Prerequisites

| Tool | Version | Note |
|---|---|---|
| Helm | 3.x (latest patch) | Helm 4 also works if kustomize is v5.8.1 or newer. |
| kustomize (standalone) | v5.8.1 or newer | Older kustomize runs `helm version -c`, which Helm 4 removed. |
| kubectl | matching your cluster's Kubernetes version | Do not rely on `kubectl kustomize`, its embedded kustomize can be older. |
| Minikube | recent | Needs about 3 nodes x 2 CPU x 3 GB. |
| Python (Ansible controller) | 3.10 to 3.12 | Supported range for ansible-core 2.16. |
| ansible-core | 2.16.x | Pinned in `ansible/requirements.txt`. |
| ansible-lint | 26.x | Pinned in `ansible/requirements.txt`. |

If Helm reports v4 and kustomize is older than v5.8.1, upgrade kustomize before building the
overlay. Always use a standalone `kustomize` binary, not the one built into `kubectl`.

## Validate everything

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r ansible/requirements.txt
make validate
```

`make validate` runs `helm lint --strict`, `helm template`, the kustomize overlay check, and
`ansible-lint` plus a playbook syntax check.

## Deploy to staging (Helm)

```bash
export REDIS_PASSWORD='<from Secret Manager>'
helm upgrade --install data-sync helm/charts/data-sync \
  --namespace data-sync --create-namespace \
  -f helm/charts/data-sync/values.staging.yaml \
  --set-string secret.redisPassword="$REDIS_PASSWORD" \
  --wait --timeout 5m
```

## Deploy to production

Two options. Only one should manage a given environment. Helm and `kubectl apply` must not
both manage the same resources.

**Option A, Kustomize overlay (recommended, adds zone spread and `SECRET_CHECKSUM`):**

```bash
export REDIS_PASSWORD='<from Secret Manager>'
printf 'secret:\n  redisPassword: "%s"\n' "$REDIS_PASSWORD" > standard/data-sync/base/secret-values.yaml
kubectl create namespace data-sync --dry-run=client -o yaml | kubectl apply -f -
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone standard/data-sync/production \
  | kubectl apply -f -
kubectl -n data-sync rollout status deploy/data-sync
git checkout standard/data-sync/base/secret-values.yaml   # never commit the real value
```

The `printf` form assumes a generated password without quotes or backslashes. Run this step
in a throwaway pipeline workspace, not on a shared checkout.

**Option B, Helm only (no overlay patches):**

```bash
helm upgrade --install data-sync helm/charts/data-sync \
  --namespace data-sync --create-namespace \
  -f helm/charts/data-sync/values.production.yaml \
  --set-string secret.redisPassword="$REDIS_PASSWORD" \
  --wait --timeout 5m
```

## Upgrade and rollback

`helm upgrade` is the same command as install. To roll back:

```bash
helm history data-sync -n data-sync
helm rollback data-sync <REVISION> -n data-sync
```

For the Kustomize path, revert the Git change to `standard/data-sync/production` and
re-apply. In an emergency, `kubectl -n data-sync rollout undo deploy/data-sync` reverts the
Deployment directly, regardless of which path deployed it.

## Values reference

| Key | Default | Staging | Production |
|---|---|---|---|
| `replicaCount` | 1 | 2 | not used (HPA owns replicas) |
| `config.logLevel` | DEBUG | INFO | INFO |
| `config.redisHost` | `redis-master.data-sync.svc.cluster.local` | `redis-staging.data-sync.internal` | `redis-prod.data-sync.internal` |
| `autoscaling.enabled` | false | false | true |
| `autoscaling.minReplicas`/`maxReplicas` | 1 / 3 | n/a | 3 / 20 |
| `resources.requests`/`limits` | 100m/128Mi, 500m/256Mi | 250m/512Mi, 1/1Gi | 2/2Gi = 2/2Gi (Guaranteed QoS) |
| `serviceMonitor.enabled` | true | true | true |
| `secret.existingSecret` | "" (chart creates the Secret) | "" | "" |

## Ansible

Setup, once:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r ansible/requirements.txt
```

Run from the `ansible/` directory:

```bash
cd ansible
ansible-playbook playbooks/playbook-data-sync.yml                 # full run: install + deploy
ansible-playbook playbooks/playbook-data-sync.yml --tags install  # prerequisites only
ansible-playbook playbooks/playbook-data-sync.yml --tags deploy   # code and config update only
ansible-playbook playbooks/playbook-data-sync.yml --check --diff  # dry run
cd ..
```

The first run on a new host must include the `install` tag (or run with no tags), since
`--tags deploy` alone fails if `/srv/data-sync` does not exist yet. `be_role` on a host
decides whether the role runs there at all: only hosts with `be_role=service` are touched.

## Local testing on Minikube

```bash
minikube start --nodes 3 --cpus 2 --memory 3072
kubectl label node minikube     topology.kubernetes.io/zone=zone-a --overwrite
kubectl label node minikube-m02 topology.kubernetes.io/zone=zone-b --overwrite
kubectl label node minikube-m03 topology.kubernetes.io/zone=zone-c --overwrite
minikube addons enable metrics-server

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.enabled=false --set alertmanager.enabled=false --wait

minikube image build -t data-sync-stub:local test/stub-app
helm upgrade --install data-sync helm/charts/data-sync \
  --namespace data-sync --create-namespace \
  -f helm/charts/data-sync/values.staging.yaml \
  -f test/minikube/values.minikube.yaml \
  --wait --timeout 5m
kubectl apply -f test/minikube/redis.yaml

kubectl -n data-sync port-forward svc/data-sync 8080:8080 &
curl -s localhost:8080/health
```

Clean up with `helm uninstall data-sync -n data-sync`, `kubectl delete -f test/minikube/redis.yaml`
and `minikube delete`. Minikube cannot prove real zone failure, node autoscaling or true
scale-out latency, only the mechanics: zone spread, checksum-driven rollouts, HPA behaviour
and the ServiceMonitor wiring.

## Assumptions and shortcuts

- "Part 4" in the brief is read as the written design (Part 3).
- The kustomization path is `standard/data-sync/production/`.
- The image repository, Redis hosts and app repo URL are placeholders.
- No Redis subchart. Bitnami moved its free versioned images to the unmaintained
  `bitnamilegacy` repo in 2025, so a test-only Redis manifest is used locally instead.
- The ServiceMonitor needs kube-prometheus-stack installed with release name
  `kube-prometheus-stack`. Set `serviceMonitor.enabled=false` on clusters without it.
- ansible-lint's `role-name` rule is skipped because the required role name `be-data-sync`
  has hyphens.
- ansible-core is pinned to 2.16 because 2.17 and newer cannot manage packages on EL8.
- Python 3.9 is what the brief asks for. It reached end of life upstream in October 2025 and
  on RHEL 8 in November 2025. Plan a move to 3.11 or 3.12.
- The PDB blocks node drains when only one replica runs (the chart default). Staging and
  production both run 2 or more replicas.

## Further reading

- [`DESIGN.md`](DESIGN.md): scaling under 20 seconds, workload isolation, secret rotation.
- [`docs/DECISIONS.md`](docs/DECISIONS.md): options considered and trade-offs.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): architecture, NFRs, maintaining this repo.
