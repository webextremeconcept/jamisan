-- Migration 004: Add pending_2fa_secret column for server-side TOTP enrolment
--
-- Security fix: the 2fa/activate endpoint previously trusted a client-supplied
-- TOTP secret. This column holds the server-generated secret between /setup and
-- /activate calls. The client never receives or returns the raw secret.
--
-- Flow:
--   1. POST /auth/2fa/setup  → generates secret, stores in pending_2fa_secret, returns QR code only
--   2. POST /auth/2fa/activate → reads pending_2fa_secret from DB, verifies TOTP code,
--      promotes to two_fa_secret, clears pending_2fa_secret

ALTER TABLE users ADD COLUMN IF NOT EXISTS pending_2fa_secret varchar(255) DEFAULT NULL;
