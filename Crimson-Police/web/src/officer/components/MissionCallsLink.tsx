// Mission call pieces on the Mission Board: the "n mission calls open" link to Dispatch, the daily-limit badge and
// the ready-check toast text (their texts live in the mission calls locale part).

import { Badge, Icon } from '../../shared/components';
import { t } from '../../shared/i18n';
import './MissionCallsLink.css';

// "n mission calls open": shown only when this unit could claim one.
export function CallsOpenLink({ n, onOpen }: { n: number; onOpen: () => void }) {
    if (!n || n <= 0) return null;
    return (
        <button type="button" className="mc-board-link" onClick={onOpen}>
            <Icon name="radio" size={15} />
            <span className="mc-board-link__text">
                {n === 1 ? t('mc.board.calls_open_one') : t('mc.board.calls_open', { n })}
            </span>
            <Icon name="chevronRight" size={14} />
        </button>
    );
}

// A type card locked by the daily cap (Config.Limits.maxCompletionsDay or the type's dailyLimit).
export function DailyLimitBadge({ locked }: { locked: unknown }) {
    if (!locked || typeof locked !== 'object' || !(locked as { daily?: boolean }).daily) return null;
    return (
        <Badge size="sm" tone="warning" icon="calendar">
            {t('mc.board.daily_limit')}
        </Badge>
    );
}

// The toast after a unit's accept went to the ready check.
export function readyCheckSentText(): string {
    return t('mc.board.ready_check_sent');
}
