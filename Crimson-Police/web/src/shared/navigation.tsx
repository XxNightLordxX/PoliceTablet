// The state-based screen switch (no router).

import { createContext, useContext } from 'react';

export type OfficerScreenKey = 'home' | 'board' | 'unit' | 'active' | 'leaderboard' | 'challenge' | 'profile';
export type SupervisorScreenKey =
    'sup_missions' | 'sup_crossdept' | 'sup_live' | 'sup_review' | 'sup_payouts' | 'sup_builder' | 'sup_report';
export type AdminScreenKey =
    | 'admin_payouts'
    | 'admin_missions'
    | 'admin_seasons'
    | 'admin_leaderboards'
    | 'admin_officers'
    | 'admin_departments'
    | 'admin_permissions'
    | 'admin_audit'
    | 'admin_testing';
export type ScreenKey = OfficerScreenKey | SupervisorScreenKey | AdminScreenKey;

export type ScreenParams = Record<string, unknown>;

export interface NavigationValue {
    // Current screen key of the open UI.
    screen: ScreenKey;
    // Params passed with the last navigate() (empty object by default).
    params: ScreenParams;
    navigate: (screen: ScreenKey, params?: ScreenParams) => void;
    // Screen keys visible in the open UI (sidebar order).
    available: ScreenKey[];
}

export const NavigationContext = createContext<NavigationValue>({
    screen: 'home',
    params: {},
    navigate: () => undefined,
    available: [],
});

export function useNavigation(): NavigationValue {
    return useContext(NavigationContext);
}

export function useNavigate(): NavigationValue['navigate'] {
    return useContext(NavigationContext).navigate;
}
