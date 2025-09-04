#!/usr/bin/env bash
set -euo pipefail
REPO_URL="${1:-https://github.com/<user>/djangoapp-.git}"
WORKDIR="${2:-$PWD/workdir}"
REGISTRY="docker.io"
REGISTRY_USER="${DOCKER_USER:-}"
REGISTRY_PASS="${DOCKER_PASS:-}"
IMAGE_PATH="${4:-$REGISTRY_USER/myapp}"
TAG="${5:-local}"

echo "==> Clone/Pull"
mkdir -p "$WORKDIR"
if [ ! -d "$WORKDIR/.git" ]; then
  git clone "$REPO_URL" "$WORKDIR"
else
  git -C "$WORKDIR" pull --rebase
fi

echo "==> Login Docker Hub"
if [ -n "$REGISTRY_USER" ] && [ -n "$REGISTRY_PASS" ]; then
  echo "$REGISTRY_PASS" | docker login -u "$REGISTRY_USER" "$REGISTRY" --password-stdin
fi

echo "==> Build"
docker build -t "$REGISTRY/$IMAGE_PATH:$TAG" -t "$REGISTRY/$IMAGE_PATH:latest" "$WORKDIR"

echo "==> Scan (Trivy)"
command -v trivy >/dev/null || { echo "Installe trivy (ou utilise l'action GitHub)"; exit 1; }
trivy image --exit-code 0 --severity MEDIUM,HIGH,CRITICAL "$REGISTRY/$IMAGE_PATH:$TAG"
trivy image --exit-code 1 --severity CRITICAL "$REGISTRY/$IMAGE_PATH:$TAG" || { echo "CRITICAL vulns"; exit 1; }

echo "==> Test run"
CID=$(docker run -d --rm -p 8000:8000 --name myapp_test "$REGISTRY/$IMAGE_PATH:$TAG")
sleep 6
curl -fsS http://127.0.0.1:8000/ >/dev/null || { echo "HTTP test failed"; docker logs --tail 100 "$CID"; docker stop "$CID"; exit 1; }
docker stop "$CID" >/dev/null

echo "==> Push"
docker push "$REGISTRY/$IMAGE_PATH:$TAG"
docker push "$REGISTRY/$IMAGE_PATH:latest"
echo "OK"
