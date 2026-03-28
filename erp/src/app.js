const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const cookieParser = require('cookie-parser');
const { globalLimiter } = require('./middleware/rateLimiter');
const authRoutes = require('./routes/auth');
const webhookRoutes = require('./routes/webhook');

const app = express();

// Security headers
app.set('trust proxy', 1); // Trust first proxy (Cloudflare / Nginx)
app.use(helmet());
app.use(cors());

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

// 404 handler
app.use((req, res) => {
  res.status(404).json({ message: 'Route not found' });
});

// Global error handler
app.use((err, req, res, _next) => {
  console.error('[Error]', err.stack || err.message);
  res.status(500).json({ message: 'Internal server error' });
});

module.exports = app;
