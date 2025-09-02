#!/usr/bin/env bash
set -euo pipefail

# ───────────────────── CONFIG ─────────────────────
# Dossier où stocker les backups
BACKUP_DIR="${BACKUP_DIR:-/var/backups/django_app}"

# Nom du service DB dans docker compose (container)
DB_SERVICE="${DB_SERVICE:-db}"

# Paramètres Postgres (doivent matcher ton docker-compose/.env)
PGHOST="${PGHOST:-$DB_SERVICE}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-bookstore}"
PGUSER="${PGUSER:-django}"
PGPASSWORD="${PGPASSWORD:-django}"

# Volumes Docker à sauvegarder (médias + statiques)
VOLUMES=(
  "${DJANGO_MEDIA_VOL:-django_media}"
  "${DJANGO_STATIC_VOL:-django_static}"
)

# Fichier docker-compose (pour démarrer la DB si besoin)
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

# Rétention (en jours)
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# Nom du projet (pour préfixer les archives)
PROJECT_NAME="${PROJECT_NAME:-bookstore}"

# Image ultralégère pour tar (busybox / alpine)
TAR_IMAGE="${TAR_IMAGE:-busybox}"

# ───────────────────── FONCTIONS ─────────────────────
log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERRO]\033[0m %s\n" "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { err "Commande requise manquante: $1"; exit 1; }
}

ensure_dir() { mkdir -p "$1"; }

compose_up_db() {
  if ! docker ps --format '{{.Names}}' | grep -qx "${PROJECT_NAME}-${DB_SERVICE}-1"; then
    log "DB non détectée en cours d'exécution → démarrage via docker compose…"
    docker compose -f "$COMPOSE_FILE" up -d "$DB_SERVICE"
  fi
}

wait_pg_ready() {
  log "Vérification disponibilité Postgres (${PGHOST}:${PGPORT})…"
  local tries=0 max=60
  until docker exec "${PROJECT_NAME}-${DB_SERVICE}-1" pg_isready -U "$PGUSER" -d "$PGDATABASE" >/dev/null 2>&1; do
    tries=$((tries+1))
    if [ "$tries" -ge "$max" ]; then
      err "Postgres indisponible après $max tentatives."
      exit 1
    fi
    sleep 2
  done
  log "Postgres est prêt."
}

backup_volume() {
  local volume="$1"
  local out_file="$2"
  log "→ Sauvegarde du volume '${volume}' → ${out_file}"
  docker run --rm \
    -v "${volume}:/src:ro" \
    -v "$(dirname "$out_file"):/dst" \
    "$TAR_IMAGE" sh -c "cd /src && tar czf \"/dst/$(basename "$out_file")\" ."
}

backup_postgres() {
  local out_file="$1"
  log "→ Dump Postgres logique → ${out_file}"
  docker exec \
    -e PGPASSWORD="$PGPASSWORD" \
    "${PROJECT_NAME}-${DB_SERVICE}-1" \
    sh -lc "pg_dump -h '$PGHOST' -p '$PGPORT' -U '$PGUSER' -d '$PGDATABASE' --no-owner --no-privileges" \
    | gzip -c > "$out_file"
}

checksum_file() {
  local file="$1"
  sha256sum "$file" > "${file}.sha256"
}

purge_old() {
  log "Nettoyage des backups de plus de ${RETENTION_DAYS} jours dans ${BACKUP_DIR}…"
  find "$BACKUP_DIR" -maxdepth 1 -type d -name "${PROJECT_NAME}_*" -mtime "+${RETENTION_DAYS}" -print -exec rm -rf {} +
}

# ───────────────────── MAIN ─────────────────────
need docker
need gzip
need sha256sum

TS="$(date +'%Y%m%d-%H%M%S')"
RUN_DIR="${BACKUP_DIR}/${PROJECT_NAME}_${TS}"
ensure_dir "$RUN_DIR"

log "Dossier de backup: $RUN_DIR"

# Sauvegarde des volumes (media/static)
for vol in "${VOLUMES[@]}"; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    OUT="${RUN_DIR}/${PROJECT_NAME}_${vol}_${TS}.tar.gz"
    backup_volume "$vol" "$OUT"
    checksum_file "$OUT"
  else
    warn "Volume '$vol' introuvable, on passe."
  fi
done

# Sauvegarde DB (dump pg_dump)
compose_up_db
wait_pg_ready
DB_OUT="${RUN_DIR}/${PROJECT_NAME}_pgdump_${PGDATABASE}_${TS}.sql.gz"
backup_postgres "$DB_OUT"
checksum_file "$DB_OUT"

# Index
{
  echo "Project:   $PROJECT_NAME"
  echo "Timestamp: $TS"
  echo "DB:        ${PGDATABASE} @ ${PGHOST}:${PGPORT} (user=${PGUSER})"
  echo "Volumes:   ${VOLUMES[*]}"
} > "${RUN_DIR}/BACKUP_INFO.txt"

purge_old

log " Sauvegarde terminée. Fichiers créés dans: $RUN_DIR"
