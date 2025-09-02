#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
HTTP_TEST_URL="http://127.0.0.1:8000/"

dc(){ if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi; }

echo "[INFO] Pull des images (Docker Hub)…"
dc -f "$COMPOSE_FILE" pull

echo "[INFO] Démarrage (up -d)…"
dc -f "$COMPOSE_FILE" up -d --force-recreate

echo "[INFO] Attente écoute port 8000 (60s max)…"
end=$((SECONDS+60))
while ! (echo >/dev/tcp/127.0.0.1/8000) 2>/dev/null; do
  (( SECONDS>=end )) && { echo "[ERREUR] Rien n'écoute sur 8000"; dc -f "$COMPOSE_FILE" logs --tail=200 web || true; exit 10; }
  sleep 1
done

echo "[INFO] Test HTTP…"
code="$(curl -s -o /dev/null -w '%{http_code}' "$HTTP_TEST_URL" || true)"
if [[ ! "$code" =~ ^(200|301|302)$ ]]; then
  echo "[ERREUR] HTTP KO (code=$code)"
  dc -f "$COMPOSE_FILE" logs --tail=200 web || true
  exit 11
fi

echo "[OK] Déploiement réussi ✅ → $HTTP_TEST_URL"
dc -f "$COMPOSE_FILE" ps
