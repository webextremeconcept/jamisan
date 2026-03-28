const rateLimit = require('express-rate-limit');

/**
 * Global rate limiter: 100 requests per 15 minutes per IP.
 * Applies to all routes.
 */
const globalLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: { message: 'Too many requests — try again later' },
});

/**
 * Auth rate limiter: 60 requests per 15 minutes per IP.
 * Applies to /auth/* routes only.
 * Account lockout (per-username, 5 attempts → 30min lock) is the primary
 * per-account protection. This rate limiter provides defence-in-depth
 * against distributed password-spray attacks from a single IP.
 */
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 60,
  standardHeaders: true,
  legacyHeaders: false,
  message: { message: 'Too many authentication attempts — try again later' },
});

module.exports = { globalLimiter, authLimiter };
