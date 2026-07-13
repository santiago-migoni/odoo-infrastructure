# Backlog

Ideas, deferred work, and future features not yet turned into a spec. Ordered by priority — items are removed automatically once `spec-flow:specify` turns them into a spec.

## P0 — Critical

- [ ] B009 Stack `monitoring` — Prometheus + Grafana + cAdvisor + node-exporter + postgres-exporter, logs centralizados con Loki + Promtail (noted 2026-07-12, from docs/features.md)
- [ ] B010 Makefile + CI/CD — Makefile como única interfaz operativa (`<stack>-<service>-<action>`), GitHub Actions con runner self-hosted, deploys automáticos a staging tras lint+tests, deploys a prod siempre manuales con aprobación (noted 2026-07-12, from docs/features.md)

## P1 — High

## P2 — Medium

- [ ] B001 PITR (point-in-time recovery) para Postgres vía WAL archiving — baja el RPO de 24h a segundos, protección continua sin releer la DB entera; forma correcta de mejorar el RPO en vez de pg_dump horario (noted 2026-07-11, from spec 004-backup-restic)
- [ ] B004 Convertir el contenedor de `backup` (`docker-compose.backup.yml`) de efímero (`run --rm`, disparado por systemd timer) a servicio estable/siempre-arriba — permite healthcheck de que está activo/funcional y trackear su consumo real de RAM en el tiempo con cAdvisor/Prometheus, cosa que un contenedor efímero no permite. Revierte la decisión de diseño actual (efímero, elegido para costo de RAM ~0 fuera de la ventana de ejecución) — evaluar el trade-off RAM 24/7 vs observabilidad continua al implementar (noted 2026-07-12, from docs/infrastructure-design.md — presupuesto de RAM)

## P3 — Low
