'use strict';
/**
 * CSR API routes — all require JWT auth (applied in app.js) + role check here.
 * Roles allowed: CSR, Operations_Manager, Director
 */
const express   = require('express');
const router    = express.Router();
const { authorize } = require('../middleware/roleMiddleware');
const ctrl      = require('../controllers/csrController');

const csr = authorize('CSR', 'Operations_Manager', 'Director');

/* ── Dashboard & orders ── */
router.get('/dashboard',                csr, ctrl.getDashboard);
router.get('/orders',                   csr, ctrl.getOrders);
router.get('/orders/:id',               csr, ctrl.getOrderPanel);
router.patch('/orders/:id',             csr, ctrl.updateOrderCtrl);
router.get('/orders/:id/history',       csr, ctrl.getOrderHistory);
router.get('/orders/:id/customer',      csr, ctrl.getCustomerIntel);
router.get('/orders/:id/copy-text',     csr, ctrl.getCopyText);

/* ── Hygiene ── */
router.get('/hygiene/counts',           csr, ctrl.getHygieneCounts);

/* ── Secondary tabs ── */
router.get('/scheduled',                csr, ctrl.getScheduled);
router.get('/agents',                   csr, ctrl.getAgents);
router.get('/contacts',                 csr, ctrl.getContacts);
router.get('/performance',              csr, ctrl.getPerformance);

/* ── User state ── */
router.patch('/break',                  csr, ctrl.toggleBreak);

/* ── Lookups ── */
router.get('/lookups/states',           csr, ctrl.getStates);
router.get('/lookups/lgas',             csr, ctrl.getLgas);
router.get('/lookups/agents-by-state',  csr, ctrl.getAgentsByState);
router.get('/lookups/products',         csr, ctrl.getProducts);
router.get('/lookups/failure-reasons',  csr, ctrl.getFailureReasons);
router.get('/lookups/failure-reasons-options', csr, ctrl.getFailureReasonsOptions);

module.exports = router;
