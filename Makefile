.DEFAULT_GOAL := help

# Toda la validación/menús/errores guiados vive en scripts/mk-dispatch.sh
# (fuente única de verdad — constitución R06). Este Makefile no sabe qué
# combinaciones son válidas, solo delega.

help:
	@./scripts/mk-dispatch.sh help

%:
	@./scripts/mk-dispatch.sh $@

.PHONY: help
