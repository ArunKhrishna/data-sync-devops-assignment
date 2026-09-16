# Architecture

## Overview

data-sync is a stateless HTTP service backed by Redis. It runs on Kubernetes behind a
ClusterIP Service, scaled by an HPA and spread across zones, with an optional Ansible path
for teams still running services on VMs. Helm owns the templates; a Kustomize overlay adds
production-only scheduling and secret-checksum concerns on top of the same chart.

```text
                    ┌────────────────────────────┐
                    │      Namespace: data-sync   │
                    │                              │
  Prometheus  <-----│  ServiceMonitor -> Service   │
  (kube-prometheus-  │        │                     │
   stack)            │        v                     │
                    │   ┌───────────────┐            │
                    │   │  Deployment    │  <--HPA----│-- metrics-server
                    │   │  (data-sync)   │            │
                    │   │  zone-a/b/c    │  <--PDB-----│
                    │   └───────┬────────┘            │
                    │           │                     │
                    │           v                     │
                    │      Redis (external           │
                    │      to this chart)             │
                    └────────────────────────────┘
```

## Components

| Component | Purpose | Where |
|---|---|---|
| Deployment | Runs the data-sync container, probes, security context | `helm/charts/data-sync/templates/deployment.yaml` |
| Service | Stable ClusterIP for the pods | `templates/service.yaml` |
| ConfigMap | Non-secret runtime config (`APP_ENV`, `REDIS_HOST`, etc.) | `templates/configmap.yaml` |
| Secret | `REDIS_PASSWORD`, created by the chart or referenced via `existingSecret` | `templates/secret.yaml` |
| ServiceAccount | Identity for the pod, token mount disabled | `templates/serviceaccount.yaml` |
| HorizontalPodAutoscaler | CPU-based replica scaling | `templates/hpa.yaml` |
| PodDisruptionBudget | Floor on available replicas during voluntary disruption | `templates/pdb.yaml` |
| ServiceMonitor | Tells Prometheus Operator to scrape `/metrics` | `templates/servicemonitor.yaml` |
| Kustomize overlay | Zone spread patch, `SECRET_CHECKSUM`, namespace pinning | `standard/data-sync/production/` |
| Ansible role `be-data-sync` | Installs and deploys data-sync on an EL8 VM as a systemd unit | `ansible/roles/be-data-sync/` |

## Configuration flow

Non-secret values flow: `values.yaml` defaults, overridden by an environment file
(`values.staging.yaml` or `values.production.yaml`), overridden again by
`test/minikube/values.minikube.yaml` for local testing only. The ConfigMap renders those
values as environment variables consumed by the container. The Secret's `redisPassword`
never lives in a committed values file for production; it arrives at deploy time via
`--set-string` (Helm path) or `standard/data-sync/base/secret-values.yaml` (Kustomize path,
generated at deploy time and reverted with `git checkout` immediately after). Both paths
render a `checksum/config` and `checksum/secret` annotation on the pod template so a config or
secret change alone is enough to trigger a rolling update, with no separate restart step.

## Environments

| Aspect | Default (chart) | Staging | Production |
|---|---|---|---|
| Replicas | 1, fixed | 2, fixed | 3 to 20, HPA-managed |
| Log level | DEBUG | INFO | INFO |
| Resources | requests below limits | requests below limits | requests equal limits |
| Autoscaling | off | off | on, 70% CPU target |
| PDB | on, minAvailable default | on | on |
| Zone spread | off (chart default) | off | on, via Kustomize overlay |
| Deploy path | n/a | Helm | Helm or Kustomize (not both) |

## Non-functional requirements

| Requirement | How it is met |
|---|---|
| Availability | multiple replicas, PDB, zone spread, readiness gating on rollout |
| Scalability | HPA with asymmetric scale-up/scale-down behavior |
| Observability | `/metrics` scraped via ServiceMonitor, `/health` for liveness/readiness/startup |
| Security | non-root, read-only root filesystem, dropped capabilities, seccomp, no auto-mounted token |
| Resource fairness | requests/limits on every pod; Guaranteed QoS in production |
| Safe rollout | checksum-triggered rolling updates, `helm rollback` / `kubectl rollout undo` as an escape hatch |
| Config separation | per-environment values files, per-environment namespaces |

## Operations

- **Deploy or upgrade**: see the README's Helm and Kustomize sections. Same `helm upgrade
  --install` command for first install and every later upgrade.
- **Roll back**: `helm rollback data-sync <REVISION> -n data-sync`, or
  `kubectl -n data-sync rollout undo deploy/data-sync` for an immediate Deployment-level
  revert regardless of which tool deployed it.
- **Rotate the Redis password**: re-run the same deploy command with a new
  `secret.redisPassword` value (Helm) or a new `standard/data-sync/base/secret-values.yaml`
  (Kustomize). The checksum annotation changes, Kubernetes rolls the Deployment, no pod ever
  runs with a stale password next to a rotated one.
- **Check autoscaling**: `kubectl -n data-sync get hpa data-sync` and
  `kubectl -n data-sync top pods` (needs metrics-server).
  Check pods are Ready.
- **Check zone spread**: `kubectl -n data-sync get pods -o wide` and cross-reference each
  node's `topology.kubernetes.io/zone` label.
- **Drain a node safely**: `kubectl drain <node> --ignore-daemonsets` respects the PDB;
  it blocks rather than dropping availability below `minAvailable`.

## Maintaining this repo

Chart template changes go in `helm/charts/data-sync/templates/`; run
`helm lint --strict` and `helm template` (via `make helm-lint helm-template` or
`make validate`) before committing. Changes to production-only scheduling or checksum
behavior go in `standard/data-sync/production/`; re-run
`scripts/verify-kustomize.sh`. Ansible role changes need `ansible-lint` at the `production`
profile (`make ansible-lint`) and, where possible, a real run against an EL8 host or VM.
Never change `data-sync.selectorLabels` in `_helpers.tpl` after a release has shipped: Helm
and Kubernetes both treat the selector as immutable, and changing it strands existing pods
that a new rollout can no longer match.

## Known limitations

- Minikube cannot demonstrate a real zone failure, real multi-zone latency or cluster-level
  node autoscaling; only the pod-level mechanics were verified there.
- The test-only Redis under `test/minikube/` has no persistence or replication and must never
  be pointed at from staging or production values.
- Python 3.9, used by the Ansible role's target VM, is past its upstream and RHEL 8 support
  windows; this follows the brief's stated target and needs a future version bump.
- The image repository, Redis hostnames and app Git repository URL are placeholders and must
  be replaced with real values before any non-Minikube deploy.
- ansible-core is pinned below 2.17 for EL8 package-manager compatibility, which also caps
  which newer Ansible features the controller can use.
