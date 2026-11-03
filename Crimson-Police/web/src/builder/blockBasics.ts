// Block settings: the basics open, the rest folded under "More settings" (Config.Builder.foldAdvanced), without
// React: whether the builder folds, and the shootout's plain Difficulty (Easy, Normal, Hard), which sets accuracy,
// armour and health inside the ranges the server sends (Config.Blocks.hostile_waves).

import type { BuilderConfig } from '../types/builder_server';
import { rangeOf, type Rng } from './schema';

// Block settings fold the advanced ones (Config.Builder.foldAdvanced); missing = on
export function foldsAdvanced(config: Pick<BuilderConfig, 'foldAdvanced'> | null | undefined): boolean {
    return !(config && config.foldAdvanced === false);
}

export const HW_DIFFICULTIES = ['easy', 'normal', 'hard'] as const;
export type HwDifficulty = (typeof HW_DIFFICULTIES)[number];
export type HwStats = { accuracy: number; armour: number; health: number };

const mid = (a: number, b: number) => Math.round((a + b) / 2);
const clamp = (v: number, r: Rng) => Math.min(r.max, Math.max(r.min, v));

// Easy: halfway from the default to the lowest (no armour); Normal: the defaults; Hard: halfway to the highest
export function hwDifficultyStats(cfg: BuilderConfig, level: HwDifficulty): HwStats {
    const ranges = {
        accuracy: rangeOf(cfg, 'hostile_waves', 'accuracy', [5, 60, 25]),
        armour: rangeOf(cfg, 'hostile_waves', 'armour', [0, 100, 0]),
        health: rangeOf(cfg, 'hostile_waves', 'health', [100, 400, 200]),
    };
    const pick = (r: Rng, low: number) =>
        clamp(level === 'easy' ? low : level === 'hard' ? mid(r.def, r.max) : r.def, r);
    return {
        accuracy: pick(ranges.accuracy, mid(ranges.accuracy.min, ranges.accuracy.def)),
        armour: pick(ranges.armour, ranges.armour.min),
        health: pick(ranges.health, mid(ranges.health.min, ranges.health.def)),
    };
}

// The level an objective's accuracy, armour and health match, or null when they were set by hand
export function hwDifficultyOf(cfg: BuilderConfig, stats: HwStats): HwDifficulty | null {
    for (const level of HW_DIFFICULTIES) {
        const s = hwDifficultyStats(cfg, level);
        if (s.accuracy === stats.accuracy && s.armour === stats.armour && s.health === stats.health) return level;
    }
    return null;
}

// "Enemies per wave": the count every wave has, or the largest when they differ (set each under More settings)
export function perWaveOf(waves: number[], fallback: number): { value: number; mixed: boolean } {
    if (!waves.length) return { value: fallback, mixed: false };
    return { value: Math.max(...waves), mixed: waves.some(w => w !== waves[0]) };
}
