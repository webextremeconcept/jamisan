/* =====================================================
   Jamisan ERP — Client-Side JavaScript
   JWT bridge, Alpine stores, clipboard, toast, auth guard
   ===================================================== */

'use strict';

/* ── Auth guard: redirect to /login if no token ── */
(function authGuard() {
  const publicPaths = ['/login', '/'];
  if (!publicPaths.includes(window.location.pathname)) {
    const token = localStorage.getItem('accessToken');
    if (!token) {
      window.location.href = '/login';
    }
  }
})();

/* ── HTMX: configRequest + responseError are in shell.ejs <head> (before HTMX loads) ── */

/* ── HTMX: handle network errors ── */
document.addEventListener('htmx:sendError', () => {
  showToast('Network error — check your connection', 'error');
});

/* ── HTMX: initialize Alpine on swapped content ── */
document.addEventListener('htmx:afterSwap', (event) => {
  if (window.Alpine) {
    Alpine.initTree(event.detail.target);
  }
});

/* ── HTMX: HX-Trigger toast — server sends { showToast: { message, type } } ── */
document.addEventListener('showToast', (e) => {
  const { message, type } = e.detail || {};
  if (message) showToast(message, type || 'error');
});

/* ── Proactive token refresh: every 13 minutes ── */
/* Access token expires at 15 min; we refresh proactively to avoid mid-request expiry */
let refreshTimer = null;
function startTokenRefresh() {
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(async () => {
    const refreshToken = localStorage.getItem('refreshToken');
    if (!refreshToken) {
      window.location.href = '/login';
      return;
    }
    try {
      const res = await fetch('/auth/refresh', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: refreshToken })
      });
      if (res.ok) {
        const data = await res.json();
        localStorage.setItem('accessToken', data.access_token);
        if (data.refresh_token) {
          localStorage.setItem('refreshToken', data.refresh_token);
        }
      } else {
        clearInterval(refreshTimer);
        localStorage.removeItem('accessToken');
        localStorage.removeItem('refreshToken');
        window.location.href = '/login';
      }
    } catch {
      // Silent fail — next interval will retry
    }
  }, 13 * 60 * 1000);
}

if (localStorage.getItem('accessToken')) {
  startTokenRefresh();
}

/* ── Toast system ── */
function showToast(message, type = 'info') {
  const container = document.getElementById('toast-container');
  if (!container) return;
  const toast = document.createElement('div');
  toast.className = 'toast toast-' + type;
  toast.textContent = message;
  container.appendChild(toast);
  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transform = 'translateY(-8px)';
    toast.style.transition = 'opacity 0.2s, transform 0.2s';
    setTimeout(() => toast.remove(), 220);
  }, 3000);
}
window.showToast = showToast;

/* ── Copy Order to clipboard ── */
async function copyOrderText(orderId) {
  try {
    const token = localStorage.getItem('accessToken');
    const res = await fetch('/api/csr/orders/' + orderId + '/copy-text', {
      headers: { 'Authorization': 'Bearer ' + token }
    });
    if (!res.ok) throw new Error('Failed to fetch copy text');
    const data = await res.json();
    await navigator.clipboard.writeText(data.text);
    showToast('Order copied to clipboard ✓', 'success');
  } catch {
    showToast('Could not copy — check browser permissions', 'error');
  }
}
window.copyOrderText = copyOrderText;

/* ── Status change handler (Alpine calls this) ── */
/* Decides whether to open a modal or fire HTMX directly */
function handleStatusChange(event, orderId, currentStatus, selectEl) {
  const newStatus = event.target.value;
  if (newStatus === currentStatus) return;

  // Store the pending change so modals can read it
  if (window.Alpine) {
    Alpine.store('ui').pendingStatusChange = { orderId, newStatus, oldStatus: currentStatus, selectEl };
  }

  if (newStatus === 'Cash Paid') {
    event.target.value = currentStatus; // Reset dropdown
    if (window.Alpine) Alpine.store('ui').cashPaidModal = true;
    return;
  }

  if (['Failed', 'Cancelled', 'Returned'].includes(newStatus)) {
    event.target.value = currentStatus; // Reset dropdown
    if (window.Alpine) Alpine.store('ui').failedModal = true;
    return;
  }

  // No modal needed — fire HTMX directly
  const tr = selectEl.closest('tr');
  htmx.ajax('PATCH', '/api/csr/orders/' + orderId, {
    source: tr,
    swap: 'outerHTML',
    target: tr,
    values: { status: newStatus }
  });
}
window.handleStatusChange = handleStatusChange;

/* ── Logout — server call FIRST (increments token_version), then clear localStorage ── */
async function logout() {
  const token = localStorage.getItem('accessToken');
  try {
    // Must await: server increments token_version to invalidate this token on all devices
    await fetch('/auth/logout', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' }
    });
  } catch { /* network error on logout — still clear local tokens and redirect */ }
  // Only clear after server confirms (or after error — token may still expire naturally)
  localStorage.removeItem('accessToken');
  localStorage.removeItem('refreshToken');
  window.location.href = '/login';
}
window.logout = logout;

/* ── Alpine.js global stores ── */
document.addEventListener('alpine:init', () => {
  Alpine.store('ui', {
    sidebarCollapsed: false,
    panelOpen: false,
    currentOrderId: null,
    panelRightCollapsed: false,
    cashPaidModal: false,
    failedModal: false,
    onBreak: document.body.dataset.onBreak === 'true',
    hasUnsavedChanges: false,
    pendingStatusChange: null,   // { orderId, newStatus, oldStatus, selectEl }

    toggleSidebar() {
      this.sidebarCollapsed = !this.sidebarCollapsed;
    },
    openPanel(orderId) {
      this.currentOrderId = orderId;
      this.panelOpen = true;
    },
    closePanel() {
      this.panelOpen = false;
      this.currentOrderId = null;
      this.hasUnsavedChanges = false;
    },
    toggleRightPanel() {
      this.panelRightCollapsed = !this.panelRightCollapsed;
    },
    cancelStatusChange() {
      // Reset the dropdown if user cancels a modal
      const change = this.pendingStatusChange;
      if (change && change.selectEl) {
        change.selectEl.value = change.oldStatus;
      }
      this.pendingStatusChange = null;
      this.cashPaidModal = false;
      this.failedModal = false;
    },
    confirmCashPaid(datePaid, agentId, logisticsFee) {
      const change = this.pendingStatusChange;
      if (!change) return;
      const tr = change.selectEl ? change.selectEl.closest('tr') : null;
      htmx.ajax('PATCH', '/api/csr/orders/' + change.orderId, {
        source: tr || document.body,
        swap: tr ? 'outerHTML' : 'none',
        target: tr || document.body,
        values: {
          status: 'Cash Paid',
          date_paid: datePaid,
          agent_id: agentId,
          logistics_fee: logisticsFee
        }
      });
      this.cashPaidModal = false;
      this.pendingStatusChange = null;
    },
    confirmFailed(newStatus, failureReasonId, comments) {
      const change = this.pendingStatusChange;
      if (!change) return;
      const tr = change.selectEl ? change.selectEl.closest('tr') : null;
      htmx.ajax('PATCH', '/api/csr/orders/' + change.orderId, {
        source: tr || document.body,
        swap: tr ? 'outerHTML' : 'none',
        target: tr || document.body,
        values: {
          status: newStatus,
          failure_reason_id: failureReasonId,
          comments
        }
      });
      this.failedModal = false;
      this.pendingStatusChange = null;
    }
  });

  Alpine.store('hygiene', {
    skipped: 0,
    no_comments: 0,
    pending: 0,
    no_logistics_fee: 0,
    no_date_paid: 0,
    abandoned: 0,
    try_again: 0,
    setAll(counts) {
      Object.assign(this, counts);
    }
  });

  Alpine.store('grid', {
    currentTab: 'all',
    currentHygiene: 'all',
    currentPage: 1,
    totalRows: 0,
    onlyMe: false,
    setTab(tab) {
      this.currentTab = tab;
      this.currentPage = 1;
    }
  });

  // Sync sidebar collapsed class — x-effect directive is unreliable for store-driven
  // class toggling on elements with empty x-data; Alpine.effect() at JS level is guaranteed reactive
  Alpine.effect(() => {
    const sidebar = document.getElementById('sidebar');
    if (sidebar) sidebar.classList.toggle('collapsed', Alpine.store('ui').sidebarCollapsed);
  });

  // Sync panel overlay open/close
  Alpine.effect(() => {
    const overlay = document.getElementById('slide-out-overlay');
    if (overlay) overlay.classList.toggle('open', Alpine.store('ui').panelOpen);
  });

  // Sync right intel panel collapsed class + chevron rotation
  Alpine.effect(() => {
    const collapsed = Alpine.store('ui').panelRightCollapsed;
    const intel = document.querySelector('.pp-intel');
    if (intel) intel.classList.toggle('pp-intel-collapsed', collapsed);
    const chevron = document.querySelector('.pp-chevron-svg');
    if (chevron) chevron.classList.toggle('pp-chevron-rotated', collapsed);
  });
});
