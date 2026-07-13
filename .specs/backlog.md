# Backlog

Ideas, deferred work, and future features not yet turned into a spec. Ordered by priority — items are removed automatically once `spec-flow:specify` turns them into a spec.

## P0 — Critical

- [ ] B010 CI/CD — GitHub Actions con runner self-hosted (polling saliente, sin puertos entrantes), pipeline Commit→Lint→Tests→Build→Deploy Staging→QA→Deploy Prod, deploys automáticos a staging tras lint+tests, deploys a prod siempre manuales con aprobación (1 approval staging / 2 main), selective module update (`-u <módulos cambiados>`), backup pre-deploy, rollback por commit SHA. Reusa los targets del Makefile (feature 008), nunca duplica lógica de deploy. La mitad "Makefile como única interfaz operativa" se separó a la feature 008-makefile (noted 2026-07-12, from docs/infrastructure-design.md; Makefile carved out 2026-07-13)

## P1 — High

## P2 — Medium

- [ ] B001 PITR (point-in-time recovery) para Postgres vía WAL archiving — baja el RPO de 24h a segundos, protección continua sin releer la DB entera; forma correcta de mejorar el RPO en vez de pg_dump horario (noted 2026-07-11, from spec 004-backup-restic)
- [ ] B004 Convertir el contenedor de `backup` (`docker-compose.backup.yml`) de efímero (`run --rm`, disparado por systemd timer) a servicio estable/siempre-arriba — permite healthcheck de que está activo/funcional y trackear su consumo real de RAM en el tiempo con cAdvisor/Prometheus, cosa que un contenedor efímero no permite. Revierte la decisión de diseño actual (efímero, elegido para costo de RAM ~0 fuera de la ventana de ejecución) — evaluar el trade-off RAM 24/7 vs observabilidad continua al implementar (noted 2026-07-12, from docs/infrastructure-design.md — presupuesto de RAM)

## P3 — Low
