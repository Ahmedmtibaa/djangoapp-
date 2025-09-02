#!/usr/bin/env bash
set -euo pipefail

# ------------- Configuration par défaut (surchargeable par options/ENV) -------------
GIT_URL="${GIT_URL:-}"                                # ex: https://github.com/Ahmedmtibaa/djangoapp-.git
CLONE_DIR="${CLONE_DIR:-./app-src}"                   # dossier de clonage
IMAGE="${IMAGE:-<DOCKERHUB_USERNAME>/myapp}"          # ex: ahmedmtibaa/myapp
TAG="${TAG:-latest}"                                  # tag de l'image
APP_PORT="${APP_PORT:-8000}"                          # port hôte -> 8000 conteneur
HEALTH_URL="${HEALTH_URL:-http://localhost:8000/}"    # URL de test
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"                    # secondes max d'attente
NO_CLONE="${NO_CLONE:-0}"                             # 1 = ne pas cloner
NO_PULL="${NO_PULL:-0}"                               # 1 = ne pas pull
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-myapp}" # préfixe compose

# ------------- Helpers -------------
log(){ printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){ printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

require_cmd(){
  command -v "$1" >/dev/null 2>&1 || { err "Commande requise manquante: $1"; exit 1; }
}

usage(){
  cat <<EOF
Usage: $0 [options]

Options:
  -g, --git URL           URL du dépôt Git à cloner (ex: https://github.com/user/repo.git)
  -d, --dir PATH          Dossier de clonage (défaut: ./app-src)
  -i, --image NAME        Image Docker Hub (ex: user/myapp) (défaut: $IMAGE)
  -t, --tag TAG           Tag de l'image (défaut: $TAG)
  -p, --port PORT         Port hôte (défaut: $APP_PORT)
  -u, --health URL        URL de santé (défaut: $HEALTH_URL)
  --no-clone              Ne pas cloner le repo
  --no-pull               Ne pas faire docker pull
  -h, --help              Afficher l'aide

Variables ENV supportées: GIT_URL, CLONE_DIR, IMAGE, TAG, APP_PORT, HEALTH_URL, WAIT_TIMEOUT, NO_CLONE, NO_PULL
EOF
}

# ------------- Parse options -------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--git) GIT_URL="$2"; shift 2;;
    -d|--dir) CLONE_DIR="$2"; shift 2;;
    -i|--image) IMAGE="$2"; shift 2;;
    -t|--tag) TAG="$2"; shift 2;;
    -p|--port) APP_PORT="$2"; shift 2;;
    -u|--health) HEALTH_URL="$2"; shift 2;;
    --no-clone) NO_CLONE=1; shift;;
    --no-pull) NO_PULL=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "Option inconnue: $1"; usage; exit 1;;
  esac
done

# ------------- Pré-checks -------------
require_cmd docker
require_cmd curl
require_cmd grep

if [[ "${NO_CLONE}" -ne 1 && -z "${GIT_URL}" ]]; then
  warn "Aucune URL Git fournie. Passe -g/--git ou exporte GIT_URL si tu veux cloner."
fi

# ------------- Étape 1: Clone du projet (si demandé) -------------
if [[ "${NO_CLONE}" -ne 1 && -n "${GIT_URL}" ]]; then
  require_cmd git
  log "Clonage du dépôt: ${GIT_URL} -> ${CLONE_DIR}"
  rm -rf "${CLONE_DIR}"
  git clone "${GIT_URL}" "${CLONE_DIR}"
else
  log "Étape clone ignorée."
fi

# ------------- Étape 2: Pull de l'image -------------
if [[ "${NO_PULL}" -ne 1 ]]; then
  log "Pull de l'image: docker.io/${IMAGE}:${TAG}"
  docker pull "docker.io/${IMAGE}:${TAG}"
else
  log "Étape pull ignorée."
fi

# ------------- Étape 3: Déploiement -------------
# Stratégie:
# - Si un docker-compose.yml existe dans ${CLONE_DIR}, on l'utilise (web/db, etc.)
# - Sinon, on lance un docker run simple sur l'image (port 8000)

USE_COMPOSE=0
COMPOSE_FILE=""
if [[ -n "${CLONE_DIR}" && -d "${CLONE_DIR}" ]]; then
  if [[ -f "${CLONE_DIR}/docker-compose.yml" ]]; then
    USE_COMPOSE=1
    COMPOSE_FILE="${CLONE_DIR}/docker-compose.yml"
  elif [[ -f "${CLONE_DIR}/compose.yml" ]]; then
    USE_COMPOSE=1
    COMPOSE_FILE="${CLONE_DIR}/compose.yml"
  fi
fi

if [[ "${USE_COMPOSE}" -eq 1 ]]; then
  require_cmd docker
  log "docker compose up (fichier: ${COMPOSE_FILE})"
  # Laisse Docker Compose fusionner un éventuel override local si présent
  ( cd "${CLONE_DIR}" && COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose up -d )
else
  CONTAINER_NAME="myapp_web_${RANDOM}"
  log "Aucun compose détecté, lancement en docker run: ${CONTAINER_NAME}"
  # Stoppe si existant
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
  docker run -d --rm \
    --name "${CONTAINER_NAME}" \
    -p "${APP_PORT}:8000" \
    "docker.io/${IMAGE}:${TAG}"

  # Enregistre le nom pour cleanup
  echo "${CONTAINER_NAME}" > .auto_deploy_last_container 2>/dev/null || true
fi

# ------------- Étape 4: Attente santé HTTP -------------
log "Test HTTP: ${HEALTH_URL} (timeout ${WAIT_TIMEOUT}s)"
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
ok=0
while [[ $(date +%s) -lt ${deadline} ]]; do
  if curl -fsS "${HEALTH_URL}" >/dev/null; then
    ok=1; break
  fi
  sleep 2
done

if [[ "${ok}" -eq 1 ]]; then
  log "✅ Application accessible: ${HEALTH_URL}"
else
  err "❌ Impossible d'atteindre ${HEALTH_URL} dans le délai imparti."
  warn "Logs récents des conteneurs:"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  # Affiche les logs du service web le plus probable
  if [[ "${USE_COMPOSE}" -eq 1 ]]; then
    ( cd "${CLONE_DIR}" && docker compose ps )
    ( cd "${CLONE_DIR}" && docker compose logs --tail=100 )
  else
    if [[ -f ".auto_deploy_last_container" ]]; then
      CN=$(cat .auto_deploy_last_container || true)
      [[ -n "${CN}" ]] && docker logs --tail=200 "${CN}" || true
    fi
  fi
  exit 1
fi

# ------------- Fin / Résumé -------------
log "Déploiement terminé."
if [[ "${USE_COMPOSE}" -eq 1 ]]; then
  log "Pour voir les logs: cd ${CLONE_DIR} && docker compose logs -f"
  log "Pour arrêter:       cd ${CLONE_DIR} && docker compose down"
else
  if [[ -f ".auto_deploy_last_container" ]]; then
    CN=$(cat .auto_deploy_last_container || true)
    [[ -n "${CN}" ]] && log "Pour voir les logs: docker logs -f ${CN}"
    [[ -n "${CN}" ]] && log "Pour arrêter:       docker stop ${CN}"
  fi
fi
