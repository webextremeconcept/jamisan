const { Router } = require('express');
const authMiddleware = require('../middleware/authMiddleware');
const { authLimiter } = require('../middleware/rateLimiter');
const {
  login,
  twoFactorVerify,
  twoFactorSetup,
  twoFactorActivate,
  refresh,
  changePassword,
  logout,
  forgotPassword,
} = require('../controllers/authController');

const router = Router();

// Apply auth-specific rate limiter to all /auth routes
router.use(authLimiter);

// Public routes (no JWT required)
router.post('/login', login);
router.post('/2fa/verify', twoFactorVerify);
router.post('/2fa/setup', twoFactorSetup);
router.post('/2fa/activate', twoFactorActivate);
router.post('/refresh', refresh);
router.post('/forgot-password', forgotPassword);

// Protected routes (JWT required)
router.patch('/password', authMiddleware, changePassword);
router.post('/logout', authMiddleware, logout);

module.exports = router;
