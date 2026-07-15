#!/bin/sh
# Dispatcher único del Makefile: traduce <verbo>-<stack>[-<servicio>] al
# docker compose real, y es la única fuente de verdad de qué combinaciones
# son válidas — el Makefile no sabe nada de esto (constitución R06).
set -e
cd "$(dirname "$0")/.."

STACKS="prod staging edge monitoring backup"
GRID_VERBS="up stop down ps logs"
MAINT_VERBS="restart pull rebuild"
ALL_VERBS="$GRID_VERBS $MAINT_VERBS"

services_for() {
  case "$1" in
    prod) echo "db pgbouncer odoo" ;;
    staging) echo "db pgbouncer odoo-staging postgres-exporter" ;;
    edge) echo "traefik cloudflared" ;;
    monitoring) echo "prometheus grafana loki promtail cadvisor node-exporter postgres-exporter-prod" ;;
    backup) echo "backup" ;;
  esac
}

compose_file_for() { echo "docker/docker-compose.$1.yml"; }

# Único lugar que sabe qué servicios se construyen acá (vs. imagen oficial).
is_own_build() {
  case "$1/$2" in
    prod/odoo|staging/odoo-staging|backup/backup) return 0 ;;
    *) return 1 ;;
  esac
}

in_list() { for i in $2; do [ "$i" = "$1" ] && return 0; done; return 1; }

# --- TAREAS (nombre propio, sin parseo verbo-stack-servicio) -----------

print_help() {
  cat <<'EOF'
odoo-infrastructure — interfaz operativa

STACKS                                                    (make <verbo>-<stack>)
  prod         up-prod  stop-prod  down-prod  ps-prod  logs-prod
  staging      up-staging  stop-staging  down-staging  ps-staging  logs-staging
  edge         up-edge  stop-edge  down-edge  ps-edge  logs-edge
  monitoring   up-monitoring  stop-monitoring  down-monitoring  ps-monitoring  logs-monitoring
  backup       up-backup  stop-backup  down-backup  ps-backup  logs-backup

  Para un servicio puntual, agregalo al final:   make logs-prod-odoo
    prod: db pgbouncer odoo          staging: db pgbouncer odoo-staging postgres-exporter
    edge: traefik cloudflared        backup: backup
    monitoring: prometheus grafana loki promtail cadvisor node-exporter postgres-exporter-prod

TAREAS
  make ps                       Estado de los 5 stacks de una
  make run-backup                Corre un backup ahora (DB + filestore -> local + R2)
  make refresh-staging           Restaura el ultimo backup de prod + anonimiza + levanta
  make restore-prod              Disaster recovery -- exige CONFIRM=yes [LOCAL=yes]
  make nuke-staging               Destruye staging y sus volumenes
  make setup-backup-role         Rol de Postgres solo-lectura para backup (una vez)
  make setup-monitoring-role     Rol de Postgres solo-lectura para monitoring (una vez)

VERBOS                                       Tipea un verbo solo para ver que acepta:
  up  stop  down  nuke  ps  logs  restart  pull  rebuild        ej.  make down
EOF
}

task_ps_global() {
  printf "%-12s %-24s %s\n" "STACK" "SERVICIO" "ESTADO"
  for s in $STACKS; do
    out=$(docker compose -f "$(compose_file_for "$s")" ps --format json 2>/dev/null || true)
    if [ -z "$out" ]; then
      printf "%-12s %-24s %s\n" "$s" "-" "-- stack abajo --"
      continue
    fi
    echo "$out" | while IFS= read -r line; do
      svc=$(echo "$line" | grep -o '"Service":"[^"]*"' | cut -d'"' -f4)
      status=$(echo "$line" | grep -o '"Status":"[^"]*"' | cut -d'"' -f4)
      printf "%-12s %-24s %s\n" "$s" "$svc" "$status"
    done
  done
}

task_nuke_menu() {
  echo "Unico comando destructivo con nombre propio:"
  echo "  make nuke-staging   Destruye staging y sus volumenes (ADVERTENCIA)"
}

task_run_menu() { echo "make run-backup   Corre el job de backup ahora"; }
task_refresh_menu() { echo "make refresh-staging   Restaura prod + anonimiza + levanta staging"; }
task_restore_menu() {
  echo "make restore-prod              Disaster recovery -- exige CONFIRM=yes [LOCAL=yes]"
  echo "make refresh-staging           Restaurar staging es siempre el ciclo completo (no hay 'restore-staging' parcial)"
}
task_setup_menu() {
  echo "make setup-backup-role"
  echo "make setup-monitoring-role"
}

alias_restore_staging() {
  cat <<'EOF'
El restore de staging es siempre el ciclo completo: restore -> anonimizacion -> up.
Nunca un restore parcial (Odoo no puede arrancar con datos de prod sin anonimizar).
Usa:  make refresh-staging
EOF
}

alias_backup() {
  cat <<'EOF'
'backup' es ambiguo -- especifica que queres:
  make up-backup    Levanta el contenedor de backup (queda arriba, sleep infinity)
  make run-backup   Corre el job de backup ahora (DB + filestore -> local + R2)
EOF
}

# --- Menu de verbo desnudo ----------------------------------------------

bare_verb_menu() {
  verb="$1"
  case " $GRID_VERBS " in
    *" $verb "*)
      echo "Combinaciones validas de '$verb':"
      for s in $STACKS; do echo "  make $verb-$s"; done
      if [ "$verb" != "down" ]; then
        echo
        echo "Para un servicio puntual, agrega el servicio al final:  make $verb-<stack>-<servicio>"
      fi
      ;;
    *)
      echo "'$verb' es por-servicio (sin variante a nivel stack). Combinaciones validas:"
      for s in $STACKS; do
        for svc in $(services_for "$s"); do
          if [ "$verb" = "pull" ] && is_own_build "$s" "$svc"; then continue; fi
          if [ "$verb" = "rebuild" ] && ! is_own_build "$s" "$svc"; then continue; fi
          echo "  make $verb-$s-$svc"
        done
      done
      ;;
  esac
}

# --- Ejecucion real -------------------------------------------------------

run_verb() {
  verb="$1"; stack="$2"; service="$3"
  file=$(compose_file_for "$stack")
  case "$verb" in
    up) docker compose -f "$file" up -d $service ;;
    stop) docker compose -f "$file" stop $service ;;
    down) docker compose -f "$file" down ;;
    ps) docker compose -f "$file" ps $service ;;
    logs) docker compose -f "$file" logs -f $service ;;
    restart) docker compose -f "$file" restart "$service" ;;
    pull) docker compose -f "$file" pull "$service" ;;
    rebuild)
      docker compose -f "$file" build --no-cache "$service"
      docker compose -f "$file" up -d "$service"
      ;;
  esac
}

# --- Parseo verbo-stack-servicio ------------------------------------------

dispatch_matrix() {
  target="$1"
  verb="${target%%-*}"

  if ! in_list "$verb" "$ALL_VERBS"; then
    echo "Comando desconocido: '$target'" >&2
    echo "Ver 'make help' para la lista de comandos." >&2
    exit 1
  fi

  rest="${target#"$verb"-}"
  if [ "$rest" = "$target" ]; then
    # no habia guion despues del verbo -> target == verbo, ya cubierto antes
    bare_verb_menu "$verb"
    return 0
  fi

  stack=""
  service=""
  for s in $STACKS; do
    if [ "$rest" = "$s" ]; then
      stack="$s"; service=""; break
    fi
    stripped="${rest#"$s"-}"
    if [ "$stripped" != "$rest" ]; then
      stack="$s"; service="$stripped"; break
    fi
  done

  if [ -z "$stack" ]; then
    echo "Stack desconocido en '$target'. Stacks validos: $STACKS" >&2
    exit 1
  fi

  if [ -n "$service" ] && ! in_list "$service" "$(services_for "$stack")"; then
    echo "Servicio desconocido '$service' en el stack '$stack'." >&2
    echo "Servicios validos de $stack: $(services_for "$stack")" >&2
    exit 1
  fi

  # Reglas de validacion por verbo
  if [ "$verb" = "down" ] && [ -n "$service" ]; then
    echo "'down' no es una operacion por-servicio (baja el stack completo)." >&2
    echo "Usa:  make stop-$stack-$service" >&2
    exit 1
  fi

  if in_list "$verb" "$MAINT_VERBS" && [ -z "$service" ]; then
    echo "'$verb' necesita un servicio -- no tiene variante a nivel stack." >&2
    bare_verb_menu "$verb" >&2
    exit 1
  fi

  if [ "$verb" = "pull" ] && [ -n "$service" ] && is_own_build "$stack" "$service"; then
    echo "'$service' se construye en este repo, no se descarga." >&2
    echo "Usa:  make rebuild-$stack-$service" >&2
    exit 1
  fi

  if [ "$verb" = "rebuild" ] && [ -n "$service" ] && ! is_own_build "$stack" "$service"; then
    echo "'$service' es imagen oficial, no se reconstruye." >&2
    echo "Usa:  make pull-$stack-$service" >&2
    exit 1
  fi

  run_verb "$verb" "$stack" "$service"
}

# --- Entrypoint -------------------------------------------------------

target="$1"

case "$target" in
  ""|help) print_help ;;
  ps) task_ps_global ;;
  nuke) task_nuke_menu ;;
  run) task_run_menu ;;
  refresh) task_refresh_menu ;;
  restore) task_restore_menu ;;
  setup) task_setup_menu ;;
  run-backup) docker compose -f docker/docker-compose.backup.yml exec -T backup /usr/local/bin/backup.sh ;;
  refresh-staging) ./scripts/refresh-staging.sh ;;
  restore-prod) ./scripts/prod-db-restore.sh ;;
  nuke-staging) ./scripts/nuke-staging.sh ;;
  setup-backup-role) ./scripts/setup-backup-role.sh ;;
  setup-monitoring-role) ./scripts/setup-monitoring-role.sh ;;
  restore-staging) alias_restore_staging ;;
  backup) alias_backup ;;
  *)
    if in_list "$target" "$ALL_VERBS"; then
      bare_verb_menu "$target"
    else
      dispatch_matrix "$target"
    fi
    ;;
esac
