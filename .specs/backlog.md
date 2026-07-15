# Backlog

Ideas, deferred work, and future features not yet turned into a spec. Ordered by priority — items are removed automatically once `spec-flow:specify` turns them into a spec.

## P0 — Critical

- [ ] B010 CI/CD — GitHub Actions con runner self-hosted (polling saliente, sin puertos entrantes), pipeline Commit→Lint→Tests→Build→Deploy Staging→QA→Deploy Prod, deploys automáticos a staging tras lint+tests, deploys a prod siempre manuales con aprobación (1 approval staging / 2 main), selective module update (`-u <módulos cambiados>`), backup pre-deploy, rollback por commit SHA. Reusa los targets del Makefile (feature 008), nunca duplica lógica de deploy. La mitad "Makefile como única interfaz operativa" se separó a la feature 008-makefile (noted 2026-07-12, from docs/infrastructure-design.md; Makefile carved out 2026-07-13)

## P1 — High

## P2 — Medium

- [ ] B011 `scripts/next-feature-number.sh` no escanea `.specs/archive/` — solo glob-ea `.specs/[0-9][0-9][0-9]-*` en el nivel superior, así que una vez que las specs convergidas se archivan ahí, devuelve `001` en vez del siguiente número real (ej. devolvió `001` con `011` ya archivada, durante la sesión que originó `012-makefile-ux`). Arreglo mínimo: que también incluya `.specs/archive/[0-9][0-9][0-9]-*` en el glob (noted 2026-07-14, from sesión de /grilling de 012-makefile-ux)

## P3 — Low
