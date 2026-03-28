-- Module 2 Auth System — Schema additions
-- Applied 2026-03-28

SET ROLE jamisan_admin;

-- token_version: incremented on logout/password change to invalidate all JWTs
ALTER TABLE users ADD COLUMN token_version integer NOT NULL DEFAULT 0;

-- failed_login_attempts: counter for account lockout (resets on success)
ALTER TABLE users ADD COLUMN failed_login_attempts integer NOT NULL DEFAULT 0;

-- locked_until: set to now() + 30min after 5 failed attempts
ALTER TABLE users ADD COLUMN locked_until timestamp DEFAULT NULL;

-- Allow null user_id in audit_log for anonymous failed login attempts
ALTER TABLE audit_log ALTER COLUMN user_id DROP NOT NULL;

-- Partial index for 24-hour login failure count queries (Gemini FIX 1)
-- Prevents full table scans as audit_log grows to millions of rows
CREATE INDEX idx_audit_log_login_failures ON audit_log (action, new_value, created_at) WHERE action = 'login_failed';
