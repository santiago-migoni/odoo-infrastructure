# Orden de features

La constitución queda aprobada como `R00`. El siguiente paso es `/specify`, que necesita una descripción de la primera feature a especificar — el diseño completo en `infrastructure-design.md` cubre mucho terreno, así que conviene trocearlo en specs manejables en vez de uno gigante.

¿Con qué feature arrancamos? Mi sugerencia de orden natural (cada una depende de la anterior):

1. **Imagen Docker + stack `prod`** (Dockerfile, `docker-compose.prod.yml`, `odoo.conf`) — la base sin la cual nada más tiene sentido.
2. **Stack `edge`** (Traefik + Cloudflare Tunnel) — para exponer lo anterior.
3. **Stack `staging` efímero** (restore + anonimización + auto-teardown).
4. **Stack `backup`** (contenedor efímero + R2).
5. **Stack `monitoring`** (Prometheus/Grafana/Loki).
6. **Makefile + CI/CD** (GitHub Actions, runner self-hosted).
