#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${MYSCOUTEE_PACKAGING_PROJECT_ROOT:-$PWD}"
SERVER_DIR="${SERVER_DIR:-${REPO_ROOT}/server}"
LOCAL_COMPOSE_PROJECT="${LOCAL_COMPOSE_PROJECT:-server}"

DRY_RUN=false
STOP_COMPOSE=true
PURGE_MONGO=true
PURGE_REDIS=true
PURGE_MINIO=true
SELECTED_DB=false

usage() {
  cat >&2 <<'USAGE'
Usage:
  npm --prefix config/packaging run development -- purge-local-datastores [options]

Purges local MyScoutee DB state from this checkout. This deletes data by
default. Pass --dry-run to preview the actions without deleting anything.

Options:
  -n, --dry-run         Preview the purge without deleting anything.
      --mongo           Purge local MongoDB data only.
      --redis           Purge local Redis state only.
      --minio           Purge local MinIO object-store data only.
      --all             Purge MongoDB, Redis, and MinIO. This is the default.
      --skip-compose    Do not stop local Docker Compose containers first.
                         With --redis, flushes the running redis container.
  -h, --help            Show this help.

Environment:
  SERVER_DIR=/path/to/server
  LOCAL_COMPOSE_PROJECT=server
  LOCAL_PURGE_HELPER_IMAGE=mongo:8.0.4
USAGE
}

fail() {
  echo "fail $1" >&2
  exit 1
}

quote_shell() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

print_command() {
  printf 'would run:'
  for arg in "$@"; do
    printf ' '
    quote_shell "$arg"
  done
  printf '\n'
}

run_command() {
  if [ "$DRY_RUN" = true ]; then
    print_command "$@"
    return 0
  fi

  "$@"
}

run_in_server() {
  if [ "$DRY_RUN" = true ]; then
    printf 'would run: cd '
    quote_shell "$SERVER_DIR"
    printf ' &&'
    for arg in "$@"; do
      printf ' '
      quote_shell "$arg"
    done
    printf '\n'
    return 0
  fi

  (cd "$SERVER_DIR" && "$@")
}

select_db() {
  if [ "$SELECTED_DB" = false ]; then
    PURGE_MONGO=false
    PURGE_REDIS=false
    PURGE_MINIO=false
    SELECTED_DB=true
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=true
      ;;
    --mongo)
      select_db
      PURGE_MONGO=true
      ;;
    --redis)
      select_db
      PURGE_REDIS=true
      ;;
    --minio)
      select_db
      PURGE_MINIO=true
      ;;
    --all)
      SELECTED_DB=true
      PURGE_MONGO=true
      PURGE_REDIS=true
      PURGE_MINIO=true
      ;;
    --skip-compose|--skip-compose-down)
      STOP_COMPOSE=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
  shift
done

[ -d "$SERVER_DIR" ] || fail "server directory not found: $SERVER_DIR"
SERVER_DIR="$(CDPATH= cd "$SERVER_DIR" && pwd)"
DATA_DIR="${SERVER_DIR}/data"
MONGO_DATA_DIR="${DATA_DIR}/mongodb"
MINIO_DATA_DIR="${DATA_DIR}/minio"

if [ "$PURGE_MONGO" = false ] && [ "$PURGE_REDIS" = false ] && [ "$PURGE_MINIO" = false ]; then
  fail "no DB selected"
fi

remove_data_dir() {
  target="$1"
  label="$2"

  case "$target" in
    "$DATA_DIR"/mongodb)
      relative_name="mongodb"
      ;;
    "$DATA_DIR"/minio)
      relative_name="minio"
      ;;
    *)
      fail "refusing to remove path outside local DB data dirs: $target"
      ;;
  esac

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    echo "Skipping missing ${label} data: $target"
    return 0
  fi

  echo "Removing ${label} data: $target"
  if [ "$DRY_RUN" = true ]; then
    print_command rm -rf -- "$target"
    return 0
  fi

  if rm -rf -- "$target" 2>/dev/null; then
    return 0
  fi

  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    echo "Normal removal failed; retrying ${label} data removal with sudo."
    sudo rm -rf -- "$target" || fail "could not remove $target with sudo"
    return 0
  fi

  if remove_data_dir_with_docker "$relative_name" "$label"; then
    return 0
  fi

  fail "could not remove $target; run this script with sudo if Docker created root-owned files"
}

docker_helper_image() {
  if [ -n "${LOCAL_PURGE_HELPER_IMAGE:-}" ]; then
    docker image inspect "$LOCAL_PURGE_HELPER_IMAGE" >/dev/null 2>&1 && {
      printf '%s\n' "$LOCAL_PURGE_HELPER_IMAGE"
      return 0
    }
    return 1
  fi

  for candidate in busybox:latest alpine:latest mongo:8.0.4; do
    if docker image inspect "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

remove_data_dir_with_docker() {
  relative_name="$1"
  label="$2"

  command -v docker >/dev/null 2>&1 || return 1
  helper_image="$(docker_helper_image)" || return 1

  echo "Normal removal failed; retrying ${label} data removal with Docker helper image: $helper_image"
  docker run --rm \
    -v "${DATA_DIR}:/myscoutee-data" \
    "$helper_image" \
    sh -c 'set -eu
target="/myscoutee-data/$1"
rm -rf -- "$target"
mkdir -p -- "$target"
chown "$2:$3" "$target" 2>/dev/null || true
' sh "$relative_name" "$(id -u)" "$(id -g)"
}

stop_local_compose() {
  if [ "$STOP_COMPOSE" = false ]; then
    echo "Skipping Docker Compose shutdown."
    return 0
  fi

  echo "Stopping local MyScoutee Docker Compose project: $LOCAL_COMPOSE_PROJECT"

  if [ "$DRY_RUN" = false ]; then
    command -v docker >/dev/null 2>&1 || fail "docker is required to stop compose containers; rerun with --skip-compose if they are already stopped"
    docker compose version >/dev/null 2>&1 || fail "docker compose is required to stop local containers"
  fi

  if [ -f "${SERVER_DIR}/docker-compose-dev.yml" ]; then
    run_in_server docker compose -p "$LOCAL_COMPOSE_PROJECT" -f docker-compose-dev.yml down -v --remove-orphans
  elif [ -f "${SERVER_DIR}/docker-compose.yml" ]; then
    run_in_server docker compose -p "$LOCAL_COMPOSE_PROJECT" -f docker-compose.yml down -v --remove-orphans
  fi

  if [ -f "${SERVER_DIR}/docker-compose-prod.yml" ]; then
    run_in_server docker compose -p "$LOCAL_COMPOSE_PROJECT" -f docker-compose-prod.yml down -v --remove-orphans
  fi
}

purge_redis() {
  if [ "$STOP_COMPOSE" = true ]; then
    echo "Redis has no bind-mounted data in the local compose files; compose down -v clears it."
    return 0
  fi

  echo "Flushing Redis container: redis"

  if [ "$DRY_RUN" = true ]; then
    print_command docker exec redis redis-cli FLUSHALL
    return 0
  fi

  command -v docker >/dev/null 2>&1 || fail "docker is required to flush Redis when --skip-compose is used"

  redis_running="$(docker container inspect -f '{{.State.Running}}' redis 2>/dev/null || true)"
  if [ "$redis_running" != true ]; then
    echo "Redis container is not running; nothing to flush."
    return 0
  fi

  docker exec redis redis-cli FLUSHALL
}

if [ "$DRY_RUN" = true ]; then
  echo "Dry-run only. Re-run without --dry-run to purge local DB state."
fi

echo "Server dir: $SERVER_DIR"
echo "Targets:"
[ "$PURGE_MONGO" = true ] && echo "  MongoDB: $MONGO_DATA_DIR"
[ "$PURGE_REDIS" = true ] && echo "  Redis: local compose container state"
[ "$PURGE_MINIO" = true ] && echo "  MinIO: $MINIO_DATA_DIR"

stop_local_compose

if [ "$PURGE_MONGO" = true ]; then
  remove_data_dir "$MONGO_DATA_DIR" "MongoDB"
  run_command mkdir -p "$MONGO_DATA_DIR"
fi

if [ "$PURGE_MINIO" = true ]; then
  remove_data_dir "$MINIO_DATA_DIR" "MinIO"
  run_command mkdir -p "$MINIO_DATA_DIR"
fi

if [ "$PURGE_REDIS" = true ]; then
  purge_redis
fi

if [ "$DRY_RUN" = true ]; then
  echo "Local DB purge dry-run complete."
else
  echo "Local DB purge complete."
fi
