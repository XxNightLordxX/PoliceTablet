// Slot: Settings → Item rewards pool editor. handlesRewardPool(path) names the settings it edits; the Settings
// screen keeps its own editor for every other path. Filled by the economy package; handles nothing until then.

import type { RewardPoolSlotProps } from '../../types/admin_control';

export function handlesRewardPool(_path: string): boolean {
    return false;
}

export function RewardPoolEditor(_props: RewardPoolSlotProps) {
    return null;
}
