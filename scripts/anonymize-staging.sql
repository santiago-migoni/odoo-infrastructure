-- Anonimización de staging. Corre contra odoo_staging, directo a db:5432,
-- ANTES de levantar el contenedor Odoo (ver scripts/staging-up.sh). Invocado
-- con `psql -v ON_ERROR_STOP=1 --single-transaction`: cualquier statement que
-- falle revierte todo y sale ≠0 — nunca queda una anonimización parcial.

-- Cortar servidores de correo saliente.
UPDATE ir_mail_server SET active = false;

-- Passwords de usuarios a valores random (nadie puede loguearse con el
-- password real de prod en staging).
UPDATE res_users SET password = md5(random()::text || id::text);

-- Emails de contactos reescritos — ningún email real de cliente queda en
-- staging, así que ningún cron de mail puede alcanzar una dirección real.
UPDATE res_partner SET email = 'staging+' || id || '@example.com' WHERE email IS NOT NULL;

-- Payment providers deshabilitados — ningún cobro/webhook real posible.
UPDATE payment_provider SET state = 'disabled';

-- Limpiar URLs de webhooks/callbacks en la config general.
DELETE FROM ir_config_parameter WHERE key ILIKE '%webhook%' OR key ILIKE '%callback_url%';

-- Desactivar crons relacionados a mail (mail queue, fetchmail, etc.).
UPDATE ir_cron SET active = false WHERE model_id IN (
  SELECT id FROM ir_model WHERE model IN ('mail.mail', 'fetchmail.server', 'mail.message')
);
