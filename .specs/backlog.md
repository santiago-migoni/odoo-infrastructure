# Backlog

Ideas, deferred work, and future features not yet turned into a spec. Ordered by priority — items are removed automatically once `spec-flow:specify` turns them into a spec.

## P0 — Critical

- [ ] B010 CI/CD — GitHub Actions con runner self-hosted (polling saliente, sin puertos entrantes), pipeline Commit→Lint→Tests→Build→Deploy Staging→QA→Deploy Prod, deploys automáticos a staging tras lint+tests, deploys a prod siempre manuales con aprobación (1 approval staging / 2 main), selective module update (`-u <módulos cambiados>`), backup pre-deploy, rollback por commit SHA. Reusa los targets del Makefile (feature 008), nunca duplica lógica de deploy. La mitad "Makefile como única interfaz operativa" se separó a la feature 008-makefile (noted 2026-07-12, from docs/infrastructure-design.md; Makefile carved out 2026-07-13)

## P1 — High

## P2 — Medium

- [ ] B011 Convertir el stack `staging` de efímero (3h + auto-teardown) a siempre-arriba con refresh semanal (restore+anonimización completo) vía systemd timer → `staging-up.sh`; elimina `staging-extend.sh` y el timer transiente de 3h; el teardown al boot se invierte a `restart: unless-stopped` (staging debe sobrevivir un reinicio, no destruirse); `staging-down` sigue siendo destructivo (`down -v`) manual, pausar sin perder datos es `docker compose stop` directo. RAM: margen permanente más ajustado (~1.9-2.3 GiB libres en vez de solo 3h/semana), aceptado explícitamente dentro de los 14 GiB actuales (noted 2026-07-13, from sesión de /grilling)
- [ ] B012 Sacar `config/odoo.conf` y `config/odoo-staging.conf` de git — patrón `.example` versionado + real gitignored en el server, igual que `.env` (permite configuración manual sin depender de un commit); agregar chequeo automático de `list_db=False`/`proxy_mode=True` al arrancar como red de seguridad mínima sobre lo no-negociable de la constitución (noted 2026-07-13, from sesión de /grilling)
- [ ] B013 Llevar el healthcheck de freshness del backup (`/backups/.last-success`, feature 009-backup-stable) a una métrica real de Prometheus — hoy solo es visible vía `docker compose ps`/`docker inspect`, cAdvisor no expone el estado de `HEALTHCHECK` de Docker como métrica (solo recursos vía cgroups). Opciones a evaluar: `textfile collector` de node-exporter escribiendo la freshness del marcador como gauge, o un exporter dedicado (noted 2026-07-14, from convergencia de 009-backup-stable — finding F1)

## P3 — Low
