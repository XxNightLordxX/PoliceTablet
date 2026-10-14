// JobProgress: a bulk job's progress from the 'adminjob' push (admin players only), for one job id or the latest.

import { useState } from 'react';
import { ProgressBar } from '../../../shared/components';
import { usePush } from '../../../shared/hooks';
import { t } from '../../../shared/i18n';
import type { AdminJobProgress } from '../../../types/admin_control';
import './kit.css';

export function useAdminJob(jobId?: string | null): AdminJobProgress | null {
    const [job, setJob] = useState<AdminJobProgress | null>(null);
    usePush<AdminJobProgress>('adminjob', next => {
        if (!next || typeof next !== 'object') return;
        if (jobId && next.id !== jobId) return;
        setJob(next);
    });
    return job;
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
