#!/usr/bin/env bash
# Builds the production overlay and checks the parts the assignment asks for.
set -euo pipefail

OVERLAY="standard/data-sync/production"
HELM_CMD="${HELM_CMD:-helm}"

out="$(kustomize build --enable-helm --load-restrictor LoadRestrictionsNone \
  --helm-command "$HELM_CMD" "$OVERLAY")"

secret_checksum="$(awk '/SECRET_CHECKSUM:/ {print $2}' <<<"$out")"
helm_checksum="$(awk '/checksum\/secret:/ {print $2}' <<<"$out")"

if [[ -z "$secret_checksum" || "$secret_checksum" != "$helm_checksum" ]]; then
  echo "FAIL: SECRET_CHECKSUM missing or does not match checksum/secret" >&2
  exit 1
fi

if ! grep -q 'topologyKey: topology.kubernetes.io/zone' <<<"$out"; then
  echo "FAIL: zone topologySpreadConstraint not found" >&2
  exit 1
fi

echo "OK: overlay builds, SECRET_CHECKSUM=${secret_checksum:0:12}..., zone spread present"
