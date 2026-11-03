// Pager: previous / next and "page n of m" for the paged admin lists (pages of at most 50 rows).

import { IconButton } from '../../../shared/components';
import { t } from '../../../shared/i18n';
import './kit.css';

export function Pager({
    page,
    pages,
    onPage,
    disabled,
}: {
    page: number;
    pages: number;
    onPage: (page: number) => void;
    disabled?: boolean;
}) {
    if (pages <= 1) return null;
    return (
        <div className="admin-kit-pager">
            <IconButton
                icon="chevronLeft"
                size="sm"
                label={t('ui.kit.page_prev')}
                disabled={disabled || page <= 1}
                onClick={() => onPage(page - 1)}
            />
            <span className="admin-kit-pager__text">{t('ui.kit.page_of', { page, pages })}</span>
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
