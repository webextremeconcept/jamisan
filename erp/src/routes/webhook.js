const express = require('express');
const webhookAuthMiddleware = require('../middleware/webhookAuthMiddleware');
const { handlePabblyWebhook } = require('../controllers/pabblyWebhookController');
const { handlePabblyReconcile } = require('../controllers/pabblyReconcileController');

const router = express.Router();

router.post('/pabbly', webhookAuthMiddleware, handlePabblyWebhook);
router.post('/pabbly-reconcile', webhookAuthMiddleware, handlePabblyReconcile);

module.exports = router;
