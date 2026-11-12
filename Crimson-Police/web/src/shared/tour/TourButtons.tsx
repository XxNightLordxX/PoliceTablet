// The ways back into a tour: the '?' button in each tablet's header (that tablet's tour from the start) and the
// Tours card (My options, Admin UI -> Settings): every tour the player may take, whether he finished it, and Start.
// Both hide while Config.Training.enabled is off.

import { Button, Card, IconButton } from '../components';
import { t } from '../i18n';
import { askTour, useTourState } from './store';
import { TOURS, toursOf, tourVersion, type TourId, type TourTablet } from './tours';

export function TourHelpButton({ tablet, className }: { tablet: TourTablet; className?: string }) {
    const { view } = useTourState();
    const tour = toursOf(tablet)[0];
    if (!tour || (view && !view.enabled)) return null;
    return (
        <IconButton
            icon="help"
            label={t('tour.ui.help')}
            className={className}
            data-tour="tour-help"
            onClick={() => askTour(tour)}
        />
    );
}

// Where a tour stands for this player: 'done', 'new' (a later version added steps) or 'todo'.
export function tourStatus(tour: TourId, seen: Partial<Record<TourId, number>> | undefined): 'done' | 'new' | 'todo' {
    const v = seen?.[tour] ?? 0;
    if (v <= 0) return 'todo';
    return v >= tourVersion(TOURS[tour]) ? 'done' : 'new';
}

// tours: the tours offered; onStart (optional) runs after a tour is asked for (e.g. a switch to its tablet).
export function ToursCard({ tours, onStart }: { tours: TourId[]; onStart?: (tour: TourId) => void }) {
    const { view } = useTourState();
    if ((view && !view.enabled) || tours.length === 0) return null;
    return (
        <Card title={t('tour.ui.list_title')} subtitle={t('tour.ui.list_help')} icon="help">
            <ul className="cp-tours">
                {tours.map(id => (
                    <li key={id} className="cp-tours__row">
                        <span className="cp-tours__name">
                            <strong>{t(`tour.name.${id}`)}</strong>
                            <span className="cp-tours__state">{t(`tour.ui.state.${tourStatus(id, view?.seen)}`)}</span>
                        </span>
                        <Button
                            size="sm"
                            variant="secondary"
                            onClick={() => {
                                askTour(id);
                                onStart?.(id);
                            }}
                        >
                            {t('tour.ui.start')}
                        </Button>
                    </li>
                ))}
            </ul>
        </Card>
    );
}
