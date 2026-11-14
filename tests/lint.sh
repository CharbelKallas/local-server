#!/bin/sh
# Static checks, no cluster needed:
#   1. shellcheck on every shell script
#   2. kubeconform (strict schema validation) on every Kubernetes manifest,
#      using the upstream schemas for core kinds and the community CRD
#      catalog for Argo CD / Kargo kinds.
#
# Uses locally installed tools when present, otherwise pinned Docker images.
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

SHELLCHECK_IMAGE="koalaman/shellcheck:v0.10.0"
KUBECONFORM_IMAGE="ghcr.io/yannh/kubeconform:v0.6.7"
K8S_VERSION="1.33.0"   # schema version; lab runs a newer K3s, schemas are stable
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

run_tool() {
  tool=$1 image=$2
  shift 2
  if command -v "$tool" >/dev/null 2>&1; then
    "$tool" "$@"
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$REPO_ROOT:/mnt:ro" -w /mnt "$image" "$@"
  else
    echo "Neither $tool nor docker is available." >&2
    exit 1
  fi
}

echo "== shellcheck =="
# shellcheck disable=SC2046
run_tool shellcheck "$SHELLCHECK_IMAGE" -x -P scripts \
  $(git ls-files --cached --others --exclude-standard '*.sh')
echo "OK"

echo
echo "== kubeconform =="
# kustomization.yaml is a kustomize config file, not a cluster resource.
manifests=$(git ls-files --cached --others --exclude-standard 'kubernetes/*.yaml' \
  | grep -v '/kustomization\.yaml$')
# shellcheck disable=SC2086
run_tool kubeconform "$KUBECONFORM_IMAGE" -strict -summary \
  -kubernetes-version "$K8S_VERSION" \
  -schema-location default -schema-location "$CRD_SCHEMAS" \
  $manifests
