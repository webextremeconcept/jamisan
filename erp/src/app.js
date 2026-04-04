const path = require('path');
const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const cookieParser = require('cookie-parser');
const { globalLimiter, csrLimiter } = require('./middleware/rateLimiter');
const authMiddleware = require('./middleware/authMiddleware');
const authRoutes = require('./routes/auth');
const webhookRoutes = require('./routes/webhook');
const pageRoutes = require('./routes/pages');
const csrRoutes = require('./routes/csr');

const app = express();

// Security headers — CSP updated to allow CDN sources for Tailwind, HTMX, Alpine, Inter font
app.set('trust proxy', 1); // Trust first proxy (Cloudflare / Nginx)
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc:    ["'self'"],
      scriptSrc:     ["'self'", "'unsafe-inline'", "'unsafe-eval'", "cdn.tailwindcss.com", "unpkg.com", "cdn.jsdelivr.net", "https://static.cloudflareinsights.com"],
      styleSrc:      ["'self'", "'unsafe-inline'", "cdn.tailwindcss.com", "fonts.googleapis.com"],
      fontSrc:       ["'self'", "fonts.gstatic.com", "data:"],
      imgSrc:        ["'self'", "data:", "blob:"],
      connectSrc:    ["'self'"],
      workerSrc:     ["'none'"],
      scriptSrcAttr: ["'unsafe-inline'"],
    },
  },
}));
app.use(cors());

// EJS view engine
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// Static assets (public/)
app.use(express.static(path.join(__dirname, '..', 'public')));

// Body parsing — scoped per route group so webhook payloads are capped at 100 kb
app.use(express.urlencoded({ extended: false }));
app.use(cookieParser());

// Global rate limiter
app.use(globalLimiter);

// Health check (no auth required)
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Auth routes
app.use('/auth', express.json({ limit: '1mb' }), authRoutes);

// Webhook routes (Pabbly order ingestion + reconciliation) — strict 100 kb body limit
app.use('/webhook', express.json({ limit: '100kb' }), webhookRoutes);

// Full-page HTML routes (/login, /dashboard, /)
app.use('/', pageRoutes);

// Redirect non-HTMX browser requests to /api/* back to /dashboard
// (handles page refresh on hx-push-url API paths)
app.use('/api', (req, res, next) => {
  if (req.method === 'GET' && !req.headers['hx-request']) {
    return res.redirect('/dashboard');
  }
  next();
});

// CSR API routes — JSON body, dedicated rate limiter (900/15min), JWT auth
// authorize() is applied per-route inside csr.js for role flexibility
app.use('/api/csr', csrLimiter, express.json({ limit: '1mb' }), authMiddleware, csrRoutes);

// 404 handler — return JSON for API paths, HTML redirect for page paths
app.use((req, res) => {
  if (req.path.startsWith('/api/')) {
    return res.status(404).json({ message: 'Route not found' });
  }
  res.redirect('/dashboard');
});

// Global error handler
app.use((err, req, res, _next) => {
  console.error('[Error]', err.stack || err.message);
  if (req.path.startsWith('/api/')) {
    return res.status(500).json({ message: 'Internal server error' });
  }
  res.status(500).send('Internal server error');
});

module.exports = app;
