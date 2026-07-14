# Backlog

Ideas, deferred work, and future features not yet turned into a spec. Ordered by priority — items are removed automatically once `spec-flow:specify` turns them into a spec.

## P0 — Critical

- [ ] B010 CI/CD — GitHub Actions con runner self-hosted (polling saliente, sin puertos entrantes), pipeline Commit→Lint→Tests→Build→Deploy Staging→QA→Deploy Prod, deploys automáticos a staging tras lint+tests, deploys a prod siempre manuales con aprobación (1 approval staging / 2 main), selective module update (`-u <módulos cambiados>`), backup pre-deploy, rollback por commit SHA. Reusa los targets del Makefile (feature 008), nunca duplica lógica de deploy. La mitad "Makefile como única interfaz operativa" se separó a la feature 008-makefile (noted 2026-07-12, from docs/infrastructure-design.md; Makefile carved out 2026-07-13)

## P1 — High

## P2 — Medium

## P3 — Low
