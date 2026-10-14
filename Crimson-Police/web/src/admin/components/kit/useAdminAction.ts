// useAdminAction: useAction for the admin actions of CP.AdminKit. Every call carries a fresh request id (the I
// guard: a double click or a resent request acts once and gets the first answer), unless opts.requestId = false.

import { useCallback } from 'react';
import { useAction, type RunOptions } from '../../../shared/hooks';
import type { ApiResult } from '../../../shared/types';

export interface AdminRunOptions extends RunOptions {
    // false = no request id (an action without the I guard); a string = reuse that id (a retry of the same click)
    requestId?: false | string;
}

// A UUID v4 (crypto.randomUUID where the browser has it).
export function newRequestId(): string {
    const c = typeof crypto !== 'undefined' ? crypto : undefined;
    if (c && typeof c.randomUUID === 'function') return c.randomUUID();
    const bytes = new Uint8Array(16);
    if (c && typeof c.getRandomValues === 'function') c.getRandomValues(bytes);
    else for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function useAdminAction(): {
    run: <T = unknown>(
        name: string,
        payload?: Record<string, unknown>,
        opts?: AdminRunOptions,
    ) => Promise<ApiResult<T>>;
    busy: boolean;
} {
    const { run: base, busy } = useAction();
    const run = useCallback(
        <T = unknown>(name: string, payload: Record<string, unknown> = {}, opts: AdminRunOptions = {}) => {
            const { requestId, ...rest } = opts;
            const body = requestId === false ? payload : { ...payload, requestId: requestId || newRequestId() };
            return base<T>(name, body, rest);
        },
        [base],
    );
    return { run, busy };
}
