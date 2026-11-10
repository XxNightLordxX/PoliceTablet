// Pager: previous / next and "page n of m" for every paged list (the Admin UI's server pages of at most 50 rows,
// and a Table with pageSize). Nothing shows for a single page.

import { t } from '../i18n';
import { IconButton } from './Button';

export interface PagerProps {
    page: number;
    pages: number;
    onPage: (page: number) => void;
    disabled?: boolean;
}

export function Pager({ page, pages, onPage, disabled }: PagerProps) {
    if (pages <= 1) return null;
    return (
        <div className="cp-pager">
            <IconButton
                icon="chevronLeft"
                size="sm"
                label={t('ui.kit.page_prev')}
                disabled={disabled || page <= 1}
                onClick={() => onPage(page - 1)}
            />
            <span className="cp-pager__text">{t('ui.kit.page_of', { page, pages })}</span>
            <IconButton
                icon="chevronRight"
                size="sm"
                label={t('ui.kit.page_next')}
                disabled={disabled || page >= pages}
                onClick={() => onPage(page + 1)}
            />
        </div>
    );
}
