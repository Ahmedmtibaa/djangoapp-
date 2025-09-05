#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- Config (ENV overridable) ----------
GIT_URL="${GIT_URL:-}"                # e.g. https://github.com/user/repo.git
CLONE_DIR="${CLONE_DIR:-./app-src}"
IMAGE="${IMAGE:-<DOCKERHUB_USERNAME>/myapp}"
TAG="${TAG:-latest}"
APP_PORT="${APP_PORT:-8000}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8000/}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
NO_CLONE="${NO_CLONE:-0}"             # 1 = skip clone
NO_PULL="${NO_PULL:-0}"               # 1 = skip docker pull
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-myapp}"

req(){ command -v "$1" >/dev/null || { echo "Missing: $1" >&2; exit 1; }; }

# ---------- Pre-checks ----------
req docker; req curl
[[ "${NO_CLONE}" -ne 1 && -n "${GIT_URL}" ]] && { req git; rm -rf "${CLONE_DIR}"; git clone "${GIT_URL}" "${CLONE_DIR}"; } || true
[[ "${NO_PULL}"  -ne 1 ]] && docker pull "docker.io/${IMAGE}:${TAG}" || true

# ---------- Deploy ----------
USE_COMPOSE=0; COMPOSE_FILE=""
if [[ -d "${CLONE_DIR}" ]]; then
  for f in docker-compose.yml compose.yml; do
    [[ -f "${CLONE_DIR}/${f}" ]] && { USE_COMPOSE=1; COMPOSE_FILE="${CLONE_DIR}/${f}"; break; }
  done
fi

if [[ "${USE_COMPOSE}" -eq 1 ]]; then
  ( cd "${CLONE_DIR}" && COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose up -d )
else
  CN="${COMPOSE_PROJECT_NAME}_web_$RANDOM"
  docker run -d --rm --name "${CN}" -p "${APP_PORT}:8000" "docker.io/${IMAGE}:${TAG}"
  echo "${CN}" > .auto_cn 2>/dev/null || true
fi

# ---------- Health check ----------
end=$(( $(date +%s) + WAIT_TIMEOUT ))
ok=0
while [[ $(date +%s) -lt $end ]]; do
  curl -fsS "${HEALTH_URL}" >/dev/null && { ok=1; break; }
  sleep 2
done

if [[ $ok -eq 1 ]]; then
  echo "OK: ${HEALTH_URL}"
else
  echo "FAILED: ${HEALTH_URL}" >&2
  if [[ "${USE_COMPOSE}" -eq 1 ]]; then
    ( cd "${CLONE_DIR}" && docker compose ps || true )
    ( cd "${CLONE_DIR}" && docker compose logs --tail=200 || true )
  else
    [[ -f .auto_cn ]] && docker logs --tail=200 "$(cat .auto_cn)" || true
  fi
  exit 1
fi

# ---------- Hints ----------
if [[ "${USE_COMPOSE}" -eq 1 ]]; then
  echo "logs:   cd ${CLONE_DIR} && docker compose logs -f"
  echo "stop:   cd ${CLONE_DIR} && docker compose down"
else
  [[ -f .auto_cn ]] && { CN=$(cat .auto_cn); echo "logs: docker logs -f ${CN}"; echo "stop: docker stop ${CN}"; }
fi
