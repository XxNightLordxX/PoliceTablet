// JobProgress: a bulk job's progress from the 'adminjob' push (admin players only), for one job id or the latest.

import { useState, useSyncExternalStore } from 'react';
import { ProgressBar } from '../../../shared/components';
import { usePush } from '../../../shared/hooks';
import { t } from '../../../shared/i18n';
import type { AdminJobProgress } from '../../../types/admin_control';
import './kit.css';

// The last 'adminjob' push of each job, kept outside React from the moment the NUI loads. The server pushes a job's
// first progress before the action replies, and a small job can be done before the reply reaches the NUI, so the
// JobProgress that the reply mounts starts from what was pushed already.
const KEPT = 50;
const lastPush = new Map<string, AdminJobProgress>();
const listeners = new Set<() => void>();

function keep(job: AdminJobProgress): void {
    lastPush.delete(job.id);
    lastPush.set(job.id, job);
    if (lastPush.size > KEPT) {
        const oldest = lastPush.keys().next().value;
        if (oldest !== undefined) lastPush.delete(oldest);
    }
    for (const l of listeners) l();
}

if (typeof window !== 'undefined') {
    window.addEventListener('message', (event: MessageEvent) => {
        const m = event.data as { type?: unknown; topic?: unknown; data?: unknown } | null;
        if (!m || typeof m !== 'object' || m.type !== 'push' || m.topic !== 'adminjob') return;
        const job = m.data as AdminJobProgress | null;
        if (job && typeof job === 'object' && typeof job.id === 'string') keep(job);
    });
}

function subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
}

export function useAdminJob(jobId?: string | null): AdminJobProgress | null {
    const kept = useSyncExternalStore(subscribe, () => (jobId ? (lastPush.get(jobId) ?? null) : null));
    // no job id: the latest job pushed while this is shown
    const [latest, setLatest] = useState<AdminJobProgress | null>(null);
    usePush<AdminJobProgress>('adminjob', next => {
        if (!jobId && next && typeof next === 'object') setLatest(next);
    });
    return jobId ? kept : latest;
}

export function JobProgress({ jobId, job: given }: { jobId?: string | null; job?: AdminJobProgress | null }) {
    const pushed = useAdminJob(jobId);
    const job = given ?? pushed;
    if (!job) return null;
    const tone =
        job.state === 'failed' || job.state === 'rolledback' ? 'danger' : job.state === 'done' ? 'success' : 'primary';
    return (
        <div className="admin-kit-job">
            <div className="admin-kit-job__line">
                <span>{t(`ui.kit.job.${job.state}`)}</span>
                <span className="cp-num">{t('ui.kit.job_rows', { done: job.done, total: job.total })}</span>
            </div>
            <ProgressBar
                value={job.total > 0 ? job.done : job.state === 'done' ? 1 : 0}
                max={job.total || 1}
                tone={tone}
            />
        </div>
    );
}
