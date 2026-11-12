// Copy one line of text for the admin (a server.cfg line, an export). FiveM's CEF usually refuses navigator.clipboard,
// so a hidden textarea and execCommand('copy') go first.

import { t } from '../../shared/i18n';
import { toast } from '../../shared/toast';

export function copyLine(text: string): boolean {
    const el = document.createElement('textarea');
    el.value = text;
    el.setAttribute('readonly', '');
    el.style.position = 'fixed';
    el.style.opacity = '0';
    document.body.appendChild(el);
    el.select();
    let ok = false;
    try {
        ok = document.execCommand('copy');
    } catch {
        ok = false;
    }
    document.body.removeChild(el);
    toast(ok ? 'success' : 'warning', t(ok ? 'sysadmin.ui.copied' : 'sysadmin.ui.copy_failed'));
    return ok;
}
