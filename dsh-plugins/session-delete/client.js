window.__ModuleLoader__.load({
  id: '@local/session-delete',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    const NS = '@local/session-delete';

    const STRINGS = {
      en: {
        'meta.title': 'Session Delete',
        'meta.description': 'Adds a Delete option to the three-dots menu of each session in the left sidebar.',
        'menu.delete': 'Delete session',
        'dialog.title': 'Delete session',
        'dialog.desc': 'Permanently delete “{title}”? Its conversation logs are removed from disk. This cannot be undone.',
        'dialog.cancel': 'Cancel',
        'dialog.delete': 'Delete',
        'dialog.deleting': 'Deleting…',
      },
      zh: {
        'menu.delete': '删除会话',
        'dialog.title': '删除会话',
        'dialog.desc': '确定要永久删除“{title}”吗？其会话日志将从磁盘移除，且无法恢复。',
        'dialog.cancel': '取消',
        'dialog.delete': '删除',
        'dialog.deleting': '正在删除…',
      },
    };

    let localeService = null;
    function t(key, params) {
      let id = 'en';
      try {
        const snap = localeService?.getLocale?.();
        if (typeof snap === 'string') id = snap;
        else if (snap && typeof snap.id === 'string') id = snap.id;
      } catch { /* fall back to English */ }
      const dict = STRINGS[id.split(/[-_]/)[0]] ?? STRINGS.en;
      let text = dict[key] ?? STRINGS.en[key] ?? key;
      if (params) for (const name of Object.keys(params)) text = text.replaceAll(`{${name}}`, String(params[name]));
      return text;
    }

    // The one pending delete request, shared between the menu row and the overlay dialog.
    let pending = null;
    let version = 0;
    const listeners = new Set();
    function setPending(next) {
      pending = next;
      version += 1;
      for (const notify of listeners) notify();
    }
    function usePending() {
      const [, force] = React.useState(0);
      React.useEffect(() => {
        let seen = version;
        const notify = () => { seen = version; force((x) => x + 1); };
        listeners.add(notify);
        if (seen !== version) force((x) => x + 1);
        return () => { listeners.delete(notify); };
      }, []);
      return pending;
    }

    const ROW_CSS = [
      '.sdd-menu-row{display:flex;align-items:center;gap:8px;width:100%;padding:6px 8px;border:0;border-radius:6px;',
      'background:transparent;color:var(--dsw-alias-state-error-primary);font:inherit;font-size:13px;line-height:20px;',
      'cursor:pointer;text-align:left;box-sizing:border-box}',
      '.sdd-menu-row:hover,.sdd-menu-row:focus-visible{background:var(--dsw-alias-bg-layer-2);outline:none}',
      '.sdd-menu-row svg{flex:none}',
    ].join('');

    function TrashIcon() {
      return h('svg', {
        width: 14, height: 14, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': 'true',
        stroke: 'currentColor', 'stroke-width': 1.3, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
      },
        h('path', { d: 'M2.5 4h11' }),
        h('path', { d: 'M5.6 4V2.8c0-.4.3-.8.8-.8h3.2c.5 0 .8.4.8.8V4' }),
        h('path', { d: 'M4.1 4l.5 9.2c0 .7.6 1.3 1.3 1.3h4.2c.7 0 1.3-.6 1.3-1.3l.5-9.2' }),
        h('path', { d: 'M6.8 6.6v5' }),
        h('path', { d: 'M9.2 6.6v5' }),
      );
    }

    function DeleteMenuItem(props) {
      const { sessionId, displayTitle, useMenuOpenState } = props;
      const setMenuOpen = useMenuOpenState()[1];
      return h(React.Fragment, null,
        h('style', null, ROW_CSS),
        h('button', {
          type: 'button',
          role: 'menuitem',
          className: 'sdd-menu-row',
          onClick: () => {
            setMenuOpen(false);
            setPending({ sessionId, displayTitle: displayTitle || sessionId });
          },
        }, h(TrashIcon, null), t('menu.delete')),
      );
    }

    const DIALOG_CSS = [
      '.sdd-backdrop{position:fixed;inset:0;z-index:100000;display:flex;align-items:center;justify-content:center;',
      'background:rgba(0,0,0,0.45)}',
      '.sdd-card{box-sizing:border-box;min-width:360px;max-width:440px;border-radius:12px;padding:18px 20px;',
      'background:var(--dsw-specific-input-major, var(--dsw-alias-bg-overlay));border:1px solid var(--dsw-alias-border-l2);',
      'box-shadow:var(--dsw-elevation-soft, 0 16px 48px rgba(0,0,0,0.32));color:var(--dsw-alias-label-primary);font:inherit}',
      '.sdd-title{font-size:14px;font-weight:600;margin-bottom:8px}',
      '.sdd-desc{font-size:13px;line-height:20px;color:var(--dsw-alias-label-secondary);margin-bottom:16px;overflow-wrap:anywhere}',
      '.sdd-error{font-size:12px;color:var(--dsw-alias-state-error-primary);margin-bottom:12px}',
      '.sdd-actions{display:flex;justify-content:flex-end;gap:8px}',
      '.sdd-btn{border-radius:6px;padding:5px 14px;border:1px solid var(--dsw-alias-border-l2);background:transparent;',
      'color:var(--dsw-alias-label-primary);font:inherit;font-size:13px;cursor:pointer}',
      '.sdd-btn:hover:not(:disabled){background:var(--dsw-alias-bg-layer-2)}',
      '.sdd-btn:disabled{opacity:0.6;cursor:default}',
      '.sdd-btn-danger{color:var(--dsw-alias-state-error-primary);border-color:var(--dsw-alias-state-error-primary)}',
    ].join('');

    function DeleteDialogForm({ request }) {
      const [busy, setBusy] = React.useState(false);
      const [error, setError] = React.useState(null);
      const close = () => { if (!busy) setPending(null); };
      React.useEffect(() => {
        const onKey = (event) => { if (event.key === 'Escape') close(); };
        window.addEventListener('keydown', onKey);
        return () => window.removeEventListener('keydown', onKey);
      }, [busy]);
      const confirm = async () => {
        setBusy(true);
        setError(null);
        try {
          const response = await fetch('/api/session-delete', {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ sessionId: request.sessionId }),
          });
          if (!response.ok) {
            let message = `Delete failed (HTTP ${String(response.status)})`;
            try {
              const value = await response.json();
              if (value && typeof value.error === 'string') message = value.error;
            } catch { /* keep the status line */ }
            throw new Error(message);
          }
          setPending(null);
        } catch (reason) {
          setBusy(false);
          setError(reason instanceof Error ? reason.message : String(reason));
        }
      };
      return h('div', {
        className: 'sdd-backdrop',
        onMouseDown: (event) => { if (event.target === event.currentTarget) close(); },
      },
        h('style', null, DIALOG_CSS),
        h('div', { role: 'dialog', 'aria-modal': 'true', 'aria-label': t('dialog.title'), className: 'sdd-card' },
          h('div', { className: 'sdd-title' }, t('dialog.title')),
          h('div', { className: 'sdd-desc' }, t('dialog.desc', { title: request.displayTitle })),
          error !== null && h('div', { role: 'alert', className: 'sdd-error' }, error),
          h('div', { className: 'sdd-actions' },
            h('button', { type: 'button', className: 'sdd-btn', disabled: busy, onClick: close }, t('dialog.cancel')),
            h('button', {
              type: 'button',
              className: 'sdd-btn sdd-btn-danger',
              disabled: busy,
              onClick: () => { void confirm(); },
            }, busy ? t('dialog.deleting') : t('dialog.delete')),
          ),
        ),
      );
    }

    function DeleteDialog() {
      const request = usePending();
      if (request === null) return null;
      return h(DeleteDialogForm, { key: request.sessionId, request });
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        localeService = ctx.get('locale');
        ctx.slots.inject('sidebar.workspaces.session.menu.item', () => ctx.slots.register({
          name: 'sidebar.workspaces.session.menu.item',
          id: 'session-delete.delete',
          order: 420,
          label: t('menu.delete'),
        }, DeleteMenuItem));
        ctx.slots.inject('shell.overlay', () => ctx.slots.register({
          name: 'shell.overlay',
          id: 'session-delete.dialog',
          order: 420,
          label: t('dialog.title'),
        }, DeleteDialog));
      },
    };
  },
});
