/**
 * Role-based access control middleware.
 *
 * Must be used AFTER authMiddleware (depends on req.user.role_name).
 *
 * Usage:
 *   router.get('/admin', authMiddleware, authorize('Director', 'Operations_Manager'), handler);
 *
 * Role names (exact strings from DB):
 *   Director, Operations_Manager, CSR, Accountant, HR,
 *   Warehouse_Coordinator, Auditor, Social_Media_Manager, Data_Analyst
 */
function authorize(...allowedRoles) {
  return (req, res, next) => {
    if (!req.user || !req.user.role_name) {
      return res.status(401).json({ message: 'Authentication required' });
    }

    if (!allowedRoles.includes(req.user.role_name)) {
      return res.status(403).json({ message: 'Forbidden — insufficient role' });
    }

    next();
  };
}

module.exports = { authorize };
