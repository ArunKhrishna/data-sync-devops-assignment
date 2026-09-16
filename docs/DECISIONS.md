# Decisions

1. **Chart delivery mechanism**
   - Chosen: Helm chart as the single source of templates, with Kustomize consuming it via
     `helmCharts` for production.
   - Alternatives: raw Kustomize bases with no Helm; a Helm chart with no Kustomize overlay.
   - Why: the brief asks for both Helm and Kustomize, and templating logic (probes, security
     context, HPA gating) belongs in one place, not duplicated across two systems.
   - Trade-off: the overlay needs a Helm binary at build time and a kustomize new enough to
     support `helmCharts` (v5.8.1+).
   - Note: kustomize-sigs' own docs advise against `helmCharts` in production, favoring a
     committed, human-rebased render instead. That warning targets third-party charts pulled
     from an external registry; ours is first-party and already reviewed in this repo. A
     static snapshot would also break secret rotation, since the checksum annotation needs a
     fresh render on every deploy to catch the current secret value. Kept live rendering.

2. **Kustomize vs Helm for production**
   - Chosen: document both as valid paths, recommend Kustomize for the zone spread patch and
     `SECRET_CHECKSUM`.
   - Alternatives: force one path only.
   - Why: some teams standardize on GitOps tools that only apply plain manifests
     (Kustomize output); others are comfortable with Helm hooks and history.
   - Trade-off: two paths mean the README must warn against running both against the same
     namespace at once.
   - Note: "Helm templates, Kustomize patches the result" is a supported upstream pattern.
     Helm ships `--post-renderer` and names Kustomize as the example; Flux's `HelmRelease`
     has a first-class `.spec.postRenderers[].kustomize` field. Those are the blessed
     mechanisms. This repo instead drives it from the Kustomize side with `helmCharts`,
     because that is the shape the brief asks for, and that path is weaker: the Kustomize
     reference calls `helmCharts` "limited support ... intended to be a limited subset of
     helm features to help with getting started", and Argo CD does not pass `--enable-helm`
     by default, so enabling it means a plugin or an instance-wide `kustomize.buildOptions`.
     On a greenfield repo the overlay would not earn its place at all: the chart is
     first-party, so `topologySpreadConstraints` is already a values key and the zone spread
     could ship from `values.production.yaml` with no Kustomize involved. Post-rendering
     would be the choice if the constraint were dropped.

3. **Secret checksum propagation into Kustomize**
   - Chosen: a `replacements` block copying the rendered `checksum/secret` annotation to a
     second `SECRET_CHECKSUM` annotation.
   - Alternatives: a custom kustomize plugin; recomputing the hash with a shell `generators`
     script.
   - Why: kustomize has no built-in hash function, but it can copy a field that Helm already
     computed.
   - Trade-off: `SECRET_CHECKSUM` is not itself consumed by anything; it exists only as an
     auditable proof that the pod template annotation moved through the overlay unchanged.

4. **Namespace strategy**
   - Chosen: one namespace per environment (`data-sync` in each cluster/context).
   - Alternatives: one shared namespace with environment-suffixed release names.
   - Why: namespace boundaries give free RBAC and NetworkPolicy scoping and match how the
     Ansible `group_vars` split staging and production.
   - Trade-off: environment-specific values files must stay disciplined, since nothing stops
     someone pointing the staging values file at the production namespace by mistake.

5. **Asymmetric CPU/memory resource shape in production**
   - Chosen: memory `requests == limits` (2Gi); CPU request 2 with the limit at 4.
   - Alternatives: `requests == limits` on both (Guaranteed QoS); a CPU request with no CPU
     limit at all.
   - Why: CPU and memory fail differently. Memory is incompressible, so going over the limit
     is an OOM kill; `requests == limits` removes the surprise at no cost. CPU is
     compressible, and a CPU limit is enforced by the kernel's CFS quota in roughly 100ms
     windows regardless of whether the node has idle CPU. That means `limit == request`
     throttles every burst above steady state (startup, GC, traffic spikes), which is the
     wrong trade for a latency-sensitive service. Putting the limit at twice the request
     keeps that burst headroom while still capping a runaway process, which is what a limit
     is for. The HPA's CPU target is computed against the request, so the limit does not
     move the scaling maths either way.
   - Trade-off: the pod is Burstable QoS, not Guaranteed, since only memory has matching
     request and limit. It is therefore not the kubelet's last-choice eviction candidate
     under generic node memory pressure. Isolation from a specific noisy neighbour
     (ClickHouse) is carried by `priorityClassName`, taints and `ResourceQuota`/`LimitRange`
     instead of by QoS class; see DESIGN.md's workload isolation section. Bursting to 4 CPUs
     also means two busy pods on one node can contend, which the topology spread and the
     dedicated node pool decision are there to bound.

6. **HPA scaling behavior**
   - Chosen: explicit `behavior.scaleUp` (fast) and `behavior.scaleDown` (slow) policies in
     production, left as HPA defaults elsewhere.
   - Alternatives: default behavior everywhere.
   - Why: default HPA behavior can scale down too eagerly right after a spike; asymmetric
     policy avoids flapping without slowing down the response to real load.
   - Trade-off: more values to tune and re-verify if traffic patterns change later.

7. **Topology spread over pod anti-affinity**
   - Chosen: `topologySpreadConstraints` with `whenUnsatisfiable: DoNotSchedule`.
   - Alternatives: `podAntiAffinity` with `requiredDuringScheduling`.
   - Why: spread constraints scale to any replica count and any number of zones without
     hardcoding pairwise rules; anti-affinity rules grow unwieldy past a handful of replicas.
   - Trade-off: `DoNotSchedule` can leave pods Pending if a zone is briefly out of capacity;
     accepted because losing schedulability is safer than losing the spread guarantee.

8. **PodDisruptionBudget presence**
   - Chosen: `pdb.enabled: true` with `minAvailable` by default.
   - Alternatives: no PDB, relying on the HPA minimum alone.
   - Why: the HPA protects against traffic-driven scale-down; only a PDB protects against
     voluntary disruption (node drains, cluster upgrades) removing too many replicas at once.
   - Trade-off: a PDB can block a node drain when replica count is at its floor; documented
     as a known interaction in the README and DESIGN.md.

9. **Ansible module style**
   - Chosen: fully qualified collection names (`ansible.builtin.yum`, not `yum`).
   - Alternatives: short module names.
   - Why: ansible-lint's production profile requires FQCN, and short names are ambiguous once
     a second collection defines a module of the same name.
   - Trade-off: more verbose task files.

10. **ansible-core version pin**
    - Chosen: `ansible-core>=2.16,<2.17`.
    - Alternatives: latest ansible-core (2.19 at time of writing).
    - Why: ansible-core 2.17 dropped `yum`/`dnf` package management support for the EL8
      target the role installs onto (Python 3.9, RHEL/Rocky 8 family).
    - Trade-off: the controller misses newer ansible-core features until the fleet moves off
      EL8.

11. **Ansible role tagging**
    - Chosen: two `import_role` calls in the playbook, tagged `install` and `deploy`
      independently, rather than tagging every task.
    - Alternatives: a single monolithic task list with per-task tags.
    - Why: operators need to re-run just the deploy step (new app version) without repeating
      package installation, and `import_role` with `tasks_from` gives that split for free.
    - Trade-off: `--tags deploy` alone fails on a brand-new host; the README documents that
      the first run needs `install` too.

12. **Git ownership during deploy**
    - Chosen: `ansible.builtin.git` runs as the app's own service user (`become_user`), not
      root.
    - Alternatives: clone as root, `chown` afterward.
    - Why: Git refuses operations on a repository owned by a different user by default; a
      `chown` afterward is an extra step that this avoids entirely.
    - Trade-off: the app user needs read access to whatever credentials the clone requires.

13. **Test Redis instead of a Helm subchart**
    - Chosen: a plain Deployment/Service manifest under `test/minikube/`, reading its
      password from the chart's own Secret.
    - Alternatives: the Bitnami Redis subchart.
    - Why: Bitnami moved its free, versioned container images to the unmaintained
      `bitnamilegacy` repository during 2025, making the previously standard subchart an
      unreliable dependency for a repo meant to demonstrate current best practice.
    - Trade-off: the test Redis is not production-representative (no persistence, no
      replication); it exists only to give the stub app something to connect to.

14. **Latest patch versions for test-only images**
    - Chosen: bump the stub app's Python base image and the test Redis image to their current
      latest patch releases, verified against Docker Hub, instead of the versions written in
      the brief.
    - Alternatives: use the brief's exact versions.
    - Why: the task explicitly calls for latest versions and no assumptions; both original
      versions had newer patch releases available at implementation time.
    - Trade-off: none functionally; documented in the relevant commit message so the
      deviation is traceable.

15. **Minikube as the only live test environment**
    - Chosen: validate everything (HPA, PDB, zone spread, secret rotation, ServiceMonitor)
      against a real 3-node Minikube cluster with faked zone labels.
    - Alternatives: static validation only (`helm template`, `kustomize build`); a real
      multi-zone cloud cluster.
    - Why: a live cluster is the only way to prove the checksum rotation triggers an actual
      rolling update and that the HPA and PDB behave as configured, without the cost or
      access requirements of a real cloud cluster.
    - Trade-off: Minikube cannot prove real zone failure or true node-level autoscaling;
      the README calls out that gap explicitly.
