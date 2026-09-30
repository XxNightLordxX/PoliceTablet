// Browser mocks for the Mission Builder server (modules/builder/server.lua, docs/notes/builder_protocol.md):

import { emitDebug, registerMock } from '../shared/nui';
import { mockLocale } from './samples';
import type {
    BuilderBonusEntry,
    BuilderBuiltinEntry,
    BuilderClientResult,
    BuilderConfig,
    BuilderDefinition,
    BuilderError,
    BuilderListEntry,
    BuilderLocation,
    BuilderLock,
    BuilderRecord,
    Vec3,
    Vec4,
} from '../types/builder_server';

const ME = 'ABC12345';
const ME_NAME = 'John Doe';
const now = () => Math.floor(Date.now() / 1000);
const isAdminView = () =>
    typeof window !== 'undefined' && new URLSearchParams(window.location.search).get('ui') === 'admin';
const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v)) as T;
const qs = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : new URLSearchParams();
const LUA = qs.get('blua') === '1';
const EDGE = qs.get('bedge') === '1';
const EMPTY = qs.get('bempty') === '1';

// What a Lua table looks like after msgpack/JSON: an empty list is {}, a nil field is missing.
function luaShape(v: unknown): unknown {
    if (Array.isArray(v)) return v.length ? v.map(luaShape) : {};
    if (v && typeof v === 'object') {
        const out: Record<string, unknown> = {};
        Object.entries(v as Record<string, unknown>).forEach(([k, x]) => {
            if (x !== null && x !== undefined) out[k] = luaShape(x);
        });
        return out;
    }
    return v;
}

// registerMock, answering in Lua shape with &blua=1.
function reg(kind: 'request' | 'action', name: string, fn: (p: any) => unknown): void {
    registerMock(kind, name, LUA ? async (p: unknown) => luaShape(await fn(p)) : fn);
}

function tr(key: string, vars: Record<string, string | number> = {}): string {
    const s = mockLocale[key] ?? key;
    return s.replace(/\{(\w+)\}/g, (m, k: string) => (vars[k] !== undefined ? String(vars[k]) : m));
}

// ============================================================================
//                                    CONFIG
// ============================================================================
// Mirrors config/config.lua Config.Builder and config/blocks.lua.

const BLOCKS: Record<string, Record<string, unknown>> = {
    details: {
        difficulty: [1, 3, 2],
        officers: [1, 4],
        timeLimit: [120, 1200, 600],
        startTimeout: [300, 900, 600],
        cooldown: [300, 3600, 1200],
        vehiclePenalties: { default: true },
    },
    hostile_waves: {
        waves: [1, 6, 3],
        perWave: [1, 15, 7],
        nextWaveAlive: [0, 5, 2],
        nextWaveAfter: [30, 300, 90],
        weapons: ['WEAPON_PISTOL', 'WEAPON_MICROSMG'],
        accuracy: [5, 60, 25],
        armour: [0, 100, 0],
        health: [100, 400, 200],
        behaviour: { options: ['hold', 'balanced', 'push'], default: 'balanced' },
        surrender: [0, 100, 30],
        peds: ['g_m_y_ballaeast_01', 'g_m_y_famca_01', 'g_m_y_mexgoon_01', 'g_m_y_lost_01'],
        boss: { default: false },
        blockTraffic: [0, 200, 120],
        spawnPointsPerHostile: 1.5,
        presenceRange: [50, 800, 150],
    },
    escort: {
        vehicle: 'stockade',
        speed: [20, 120, 60],
        style: { options: ['careful', 'normal', 'fast'], default: 'normal' },
        toughness: [0.5, 3.0, 1.5],
        stoppedFail: [15, 120, 60],
        arrival: [10, 50, 20],
        stops: [0, 5, 0],
        stopWait: [10, 60, 20],
        ambushPoints: [1, 10, 5],
        ambushGap: 150.0,
        ambushWaves: [1, 5, 2],
        carsPerWave: [1, 5, 2],
        perCar: [1, 4, 2],
        presenceRange: [50, 800, 300],
    },
    pursuit: {
        mode: { options: ['follow', 'stop'], default: 'stop' },
        vehicles: [1, 5, 1],
        route: { options: ['free', 'recorded'], default: 'free' },
        speed: [40, 160, 120],
        style: { options: ['cautious', 'reckless'], default: 'reckless' },
        suspects: [1, 4, 1],
        footFlee: [0, 100, 20],
        holdDistance: [50, 300, 150],
        lostDistance: [150, 600, 250],
        lostSeconds: [5, 30, 10],
        duration: [60, 600, 180],
        presenceRange: [50, 800, 400],
    },
    checkpoint_route: {
        checkpoints: [2, 20],
        use: { options: ['all', 'random'], default: 'all' },
        radius: [3, 20, 10],
        stopFor: [0, 30, 10],
        vehicleRequired: { default: true },
        medals: { default: false },
        contactPenalty: [0, 10, 2],
        presenceRange: [50, 800, 300],
    },
    interact_points: {
        points: [1, 10],
        use: { options: ['all', 'random'], default: 'all' },
        progress: [1, 30, 5],
        label: 'Checking…',
        animation: 'clipboard',
        logResult: { default: false },
        logChoices: [2, 4, 2],
        presenceRange: [50, 800, 150],
    },
    skill_check: {
        checks: [1, 8, 4],
        difficulty: { options: ['easy', 'medium', 'hard'], default: ['easy', 'medium', 'medium', 'hard'] },
        missPenalty: [0, 120, 30],
        failAfter: [1, 3, 2],
        presenceRange: [50, 800, 150],
    },
    protect_rescue: {
        npcs: [1, 6, 3],
        peds: ['a_m_m_business_01', 'a_f_y_business_01'],
        restrained: { default: true },
        freeTime: [1, 15, 6],
        hitPenalty: [0, 100, 50],
        failIfDies: { default: true },
        presenceRange: [50, 800, 150],
    },
    flee_arrest: {
        suspects: [1, 10, 1],
        responses: { surrender: 50, flee: 30, fight: 20 },
        armedChance: [0, 100, 20],
        weapons: ['WEAPON_PISTOL'],
        escapeDistance: [200, 800, 400],
        escapeSeconds: [10, 60, 20],
        givesUp: { options: ['aim', 'stun', 'close'], default: ['aim', 'stun', 'close'] },
        aimDistance: [5, 15, 10],
        closeDistance: 3.0,
        closeSeconds: 3,
        presenceRange: [50, 800, 250],
    },
    search_area: {
        startRadius: [200, 1000, 600],
        clues: [1, 5, 3],
        shrinkTo: [300, 150, 50],
        fugitives: [1, 5, 1],
        runDistance: [10, 60, 30],
        presenceRange: [50, 800, 100],
    },
};

const DEFAULT_MIN_SECONDS: Record<string, number> = {
    checkpoint_route: 20,
    interact_points: 5,
    skill_check: 10,
    hostile_waves: 60,
    protect_rescue: 15,
    flee_arrest: 30,
    pursuit: 30,
    escort: 60,
    search_area: 60,
};

const BONUSES: BuilderConfig['bonuses'] = [
    {
        id: 'clues_first',
        kind: 'points',
        value: 10,
        each: false,
        block: 'search_area',
        penalty: false,
        labelKey: 'bonus.clues_first',
    },
    {
        id: 'correct_log',
        kind: 'points',
        value: 5,
        each: true,
        block: 'interact_points',
        penalty: false,
        labelKey: 'bonus.correct_log',
    },
    {
        id: 'hard_ram',
        kind: 'points',
        value: -10,
        each: true,
        block: 'pursuit',
        penalty: true,
        labelKey: 'penalty.hard_ram',
    },
    {
        id: 'hostile_arrested',
        kind: 'points',
        value: 5,
        each: true,
        block: 'hostile_waves',
        penalty: false,
        labelKey: 'bonus.hostile_arrested',
    },
    {
        id: 'no_hostage_hurt',
        kind: 'points',
        value: 15,
        each: false,
        block: 'protect_rescue',
        penalty: false,
        labelKey: 'bonus.no_hostage_hurt',
    },
    {
        id: 'no_missed_checks',
        kind: 'points',
        value: 15,
        each: false,
        block: 'skill_check',
        penalty: false,
        labelKey: 'bonus.no_missed_checks',
    },
    {
        id: 'no_participant_downed',
        kind: 'pct',
        value: 10,
        each: false,
        block: null,
        penalty: false,
        labelKey: 'bonus.no_participant_downed',
    },
    {
        id: 'no_weapons_fired',
        kind: 'points',
        value: 10,
        each: false,
        block: null,
        penalty: false,
        labelKey: 'bonus.no_weapons_fired',
    },
    {
        id: 'suspect_alive',
        kind: 'points',
        value: 15,
        each: false,
        block: 'flee_arrest',
        penalty: false,
        labelKey: 'bonus.suspect_alive',
    },
    {
        id: 'truck_healthy',
        kind: 'pct',
        value: 10,
        each: false,
        block: 'escort',
        penalty: false,
        labelKey: 'bonus.truck_healthy',
    },
    {
        id: 'vehicle_stopped_fast',
        kind: 'points',
        value: 15,
        each: false,
        block: 'pursuit',
        penalty: false,
        labelKey: 'bonus.vehicle_stopped_fast',
    },
    {
        id: 'wrong_log',
        kind: 'points',
        value: -5,
        each: true,
        block: 'interact_points',
        penalty: true,
        labelKey: 'penalty.wrong_log',
    },
];

const MISSION_TYPES = [
    { key: 'patrol', label: 'Patrol', points: 60 },
    { key: 'training', label: 'Training', points: 100 },
    { key: 'investigation', label: 'Investigation', points: 160 },
    { key: 'tactical', label: 'Tactical', points: 200 },
];
const TIERS = [
    { name: 'standard', labelKey: 'tier.standard', maxParticipants: 1 },
    { name: 'reinforced', labelKey: 'tier.reinforced', maxParticipants: 2 },
    { name: 'heavy', labelKey: 'tier.heavy', maxParticipants: 4 },
    { name: 'major', labelKey: 'tier.major', maxParticipants: 6 },
    { name: 'critical', labelKey: 'tier.critical', maxParticipants: 8 },
];
const tierFor = (n: number) => (TIERS.find(t => t.maxParticipants >= n) ?? TIERS[TIERS.length - 1]).name;

function buildConfig(): BuilderConfig {
    const admin = isAdminView();
    return {
        enabled: true,
        blocks: BLOCKS,
        blockList: Object.keys(BLOCKS)
            .filter(k => k !== 'details')
            .sort()
            .map(id => ({
                id,
                labelKey: `builder.block.${id}`,
                available: true,
                minSeconds: DEFAULT_MIN_SECONDS[id] ?? 0,
                presenceRange: (BLOCKS[id].presenceRange as [number, number, number]) ?? null,
            })),
        allowed: {
            weapons: [
                'WEAPON_PISTOL',
                'WEAPON_COMBATPISTOL',
                'WEAPON_MICROSMG',
                'WEAPON_SMG',
                'WEAPON_PUMPSHOTGUN',
                'WEAPON_ASSAULTRIFLE',
            ],
            peds: [
                'g_m_y_ballaeast_01',
                'g_m_y_famca_01',
                'g_m_y_mexgoon_01',
                'g_m_y_lost_01',
                'a_m_m_business_01',
                'a_f_y_business_01',
                's_m_y_prisoner_01',
                's_m_y_prismuscl_01',
                'g_m_m_armboss_01',
                's_m_m_armoured_01',
            ],
            vehicles: ['sultan', 'buffalo', 'elegy2', 'kuruma', 'dominator'],
            escortVehicles: ['stockade', 'stockade3'],
            animations: ['clipboard', 'search', 'kneel', 'mechanic'],
        },
        maxHostiles: 40,
        maxBlocks: 6,
        minLocations: 3,
        maxLocations: 20,
        minLocationGap: 100,
        minSpawnFromStart: 30,
        bonusCap: { points: 50, pct: 25 },
        bonuses: BONUSES,
        noBuildZones: EDGE
            ? []
            : [
                  { label: 'Mission Row PD and FIB HQ', coords: { x: 470.63, y: -974.11, z: 30.18 }, radius: 120 },
                  { label: 'Sandy Shores BCSO', coords: { x: 1833.06, y: 3679.32, z: 33.19 }, radius: 80 },
                  { label: 'SASP HQ', coords: { x: 1560.38, y: 815.76, z: 76.21 }, radius: 80 },
                  { label: 'Pillbox Hill Medical', coords: { x: 308.19, y: -595.35, z: 43.29 }, radius: 100 },
                  { label: 'Paleto Bay Medical', coords: { x: -254.54, y: 6331.78, z: 32.43 }, radius: 80 },
                  { label: 'Bolingbroke interior', coords: { x: 1768.73, y: 2570.43, z: 44.73 }, radius: 180 },
                  { label: 'Crimson-Arena Trailer Park', coords: { x: 2344.43, y: 2565.06, z: 46.67 }, radius: 160 },
                  { label: 'Crimson-Arena lobby', coords: { x: -282.01, y: -2030.46, z: 30.15 }, radius: 60 },
              ],
        departments: [
            { key: 'fib', label: 'Federal Investigation Bureau', short: 'FIB' },
            { key: 'sast', label: 'San Andreas State Troopers', short: 'SAST' },
        ],
        missionTypes: MISSION_TYPES,
        tiers: TIERS,
        autosaveSeconds: 30,
        editLockMinutes: 30,
        testAtMaxTier: true,
        keepBackups: true,
        exportPath: 'missions/custom/',
        route: {
            snapEvery: 25,
            maxOffRoad: 8,
            turnAngle: 30,
            maxGap: 150,
            minLength: 800,
            maxLength: 8000,
            minStartEndGap: 300,
            loopClose: 50,
            undoMetres: 100,
            testDriveTimeout: 30,
        },
        startRadius: [20, 150, 60],
        maxItems: 10,
        itemCount: [1, 100],
        maxScaling: 20,
        limits: { label: 64, description: 500, objectiveLabel: 64, locationLabel: 64 },
        percentFields: {
            hostile_waves: ['surrender.chance', 'boss.surrender.chance'],
            flee_arrest: ['responses.surrender', 'responses.flee', 'responses.fight', 'armedShare'],
            pursuit: ['footFlee'],
            interact_points: ['roll.outcomes.*.chance'],
        },
        secondsFields: {
            interact_points: ['progress.duration', 'roll.outcomes.*.followUp.duration'],
            protect_rescue: ['freeTime'],
            flee_arrest: ['knock.duration', 'cuff.duration'],
            hostile_waves: ['cuff.duration'],
            pursuit: ['arrest.duration'],
            search_area: ['clueProgress.duration', 'cuff.duration'],
        },
        spawnFields: {
            hostile_waves: ['spawns', 'boss.spawn'],
            protect_rescue: ['npcs'],
            flee_arrest: ['suspect', 'associates.spawns', 'spawns'],
            pursuit: ['spawn', 'spawns'],
            escort: ['ambushPoints'],
            search_area: ['hiding'],
        },
        forbiddenItems: ['armour', 'bandage', 'ammo-*', 'weapon_*'],
        useStartRoute: false,
        permissions: {
            builderEdit: true,
            builderEditAny: admin,
            builderPublish: true,
            builderArchive: true,
            builderRollback: admin,
            breakEditLock: admin,
        },
    };
}

// ============================================================================
//                              SAMPLE DEFINITIONS
// ============================================================================

const v3 = (x: number, y: number, z: number): Vec3 => ({ x, y, z });
const v4 = (x: number, y: number, z: number, w: number): Vec4 => ({ x, y, z, w });

function spawnRing(c: Vec3, n: number, r = 45): Vec4[] {
    return Array.from({ length: n }, (_, i) => {
        const a = (i / n) * Math.PI * 2;
        return v4(
            Math.round((c.x + Math.cos(a) * r) * 100) / 100,
            Math.round((c.y + Math.sin(a) * r) * 100) / 100,
            c.z,
            Math.round(((a * 180) / Math.PI + 180) % 360),
        );
    });
}

function dockLocation(label: string, c: Vec3): BuilderLocation {
    return {
        label,
        start: { coords: c, radius: 60 },
        spawns: spawnRing(c, 11),
        evidence: [
            v3(c.x + 38.4, c.y - 12.1, c.z + 0.4),
            v3(c.x + 41.2, c.y - 10.5, c.z + 0.4),
            v3(c.x + 36.9, c.y - 15.8, c.z + 0.4),
        ],
    };
}

function docksideRaid(accuracy = 30): BuilderDefinition {
    return {
        id: 'custom_dockside_raid',
        label: 'Dockside Raid',
        description: 'A smuggling crew is unloading at the docks. Clear the dock and seize the shipment.',
        type: 'tactical',
        departments: [],
        minOfficers: 2,
        maxOfficers: 4,
        difficulty: 3,
        timeLimit: 720,
        startTimeout: 600,
        cooldown: 1200,
        vehiclePenalties: false,
        locations: [
            dockLocation('Dock 1 · Elysian Island', v3(1017.52, -3108.44, 5.9)),
            dockLocation('Dock 2 · Terminal', v3(1236.8, -3006.2, 5.87)),
            dockLocation('Dock 3 · Pier 400', v3(-139.3, -2607.9, 6.0)),
        ],
        objectives: [
            {
                block: 'hostile_waves',
                label: 'Clear the dock',
                minSeconds: 45,
                presenceRange: 150,
                waves: [6, 6],
                nextWave: { aliveAtMost: 2, afterSeconds: 90 },
                weapons: ['WEAPON_PISTOL', 'WEAPON_SMG'],
                accuracy,
                armour: 10,
                surrender: { belowHealth: 0.25, chance: 30 },
                blockTraffic: 120,
            },
            {
                block: 'interact_points',
                label: 'Seize the shipment',
                minSeconds: 6,
                presenceRange: 150,
                points: 'evidence',
                progress: { label: 'Seizing crates', duration: 6, anim: 'search' },
            },
        ],
        scaling: ['objectives.1.waves'],
        items: [],
        bonuses: [
            { id: 'no_participant_downed', pct: 10 },
            { id: 'hostile_arrested', points: 5 },
        ],
        penalties: [],
    };
}

function harbourSweep(): BuilderDefinition {
    const d = docksideRaid();
    return {
        ...d,
        id: 'custom_harbour_sweep',
        label: 'Harbour Sweep',
        type: 'investigation',
        minOfficers: 1,
        maxOfficers: 2,
        difficulty: 2,
        description: 'Check the moored boats for stolen goods before the night shift ends.',
        locations: d.locations.slice(0, 2).map(l => ({ ...l, spawns: undefined })),
        objectives: [
            {
                block: 'interact_points',
                label: 'Check the boats',
                minSeconds: 20,
                presenceRange: 150,
                points: 'evidence',
                use: 'all',
                progress: { label: 'Checking the boat', duration: 5, anim: 'clipboard' },
                roll: {
                    outcomes: [
                        { id: 'clear', chance: 70 },
                        { id: 'goods', chance: 30, followUp: { label: 'Bag the goods', duration: 4 } },
                    ],
                },
            },
        ],
        scaling: [],
        bonuses: [{ id: 'no_weapons_fired', points: 10 }],
    };
}

function vinewoodStakeout(): BuilderDefinition {
    return {
        id: 'custom_vinewood_stakeout',
        label: 'Vinewood Stakeout',
        description: 'A wanted fence is meeting buyers above Vinewood Boulevard.',
        type: 'investigation',
        departments: ['fib'],
        minOfficers: 1,
        maxOfficers: 3,
        difficulty: 2,
        timeLimit: 900,
        startTimeout: 600,
        cooldown: 1800,
        vehiclePenalties: true,
        locations: [
            {
                label: 'Hotel roof',
                start: { coords: v3(351.2, 186.4, 103.1), radius: 50 },
                door: v4(356.4, 212.9, 103.1, 160),
                suspect: v4(398.6, 221.3, 103.1, 70),
                fleeTo: [v3(420.1, 240.2, 103.1)],
            },
            {
                label: 'Gallery alley',
                start: { coords: v3(-85.6, 231.9, 97.2), radius: 50 },
                door: v4(-60.2, 212.0, 97.2, 90),
                suspect: v4(-40.7, 255.6, 97.2, 0),
                fleeTo: [v3(-18.3, 260.1, 97.2)],
            },
            {
                label: 'Diner lot',
                start: { coords: v3(129.9, 305.4, 111.9), radius: 50 },
                door: v4(160.4, 317.8, 111.9, 200),
                suspect: v4(171.3, 343.1, 111.9, 30),
                fleeTo: [v3(200.0, 360.0, 111.9)],
            },
        ],
        objectives: [
            {
                block: 'flee_arrest',
                label: 'Arrest the fence',
                minSeconds: 30,
                presenceRange: 250,
                mode: 'door',
                responses: { surrender: 50, flee: 30, fight: 20 },
                knock: { label: 'Knock and announce', duration: 3 },
                associates: { count: 0 },
            },
        ],
        scaling: [],
        items: [],
        bonuses: [{ id: 'suspect_alive', points: 15 }],
        penalties: [],
    };
}

function quarryEscort(): BuilderDefinition {
    const pts: Vec3[] = Array.from({ length: 24 }, (_, i) => v3(2690 + i * 55.5, 2860 - i * 31.25, 43));
    return {
        id: 'custom_quarry_escort',
        label: 'Quarry Escort',
        description: 'Move seized explosives from the quarry to the Sandy Shores airfield.',
        type: 'tactical',
        departments: [],
        minOfficers: 2,
        maxOfficers: 4,
        difficulty: 3,
        timeLimit: 1080,
        startTimeout: 600,
        cooldown: 2400,
        vehiclePenalties: false,
        locations: [1, 2, 3].map(n => ({
            label: `Quarry gate ${n}`,
            start: { coords: v3(2680 + n * 200, 2870, 43), radius: 60 },
            route: { points: pts, stops: [{ at: 12, wait: 20 }] },
            ambushPoints: [
                v3(2900, 2740, 43),
                v3(3100, 2630, 43),
                v3(3300, 2515, 43),
                v3(3500, 2400, 43),
                v3(3700, 2290, 43),
            ],
        })),
        objectives: [
            {
                block: 'escort',
                label: 'Escort the truck',
                minSeconds: 120,
                presenceRange: 300,
                route: 'route',
                vehicle: 'stockade',
                speed: 60,
                style: 'normal',
            },
        ],
        scaling: ['objectives.1.ambush.waves'],
        items: [],
        bonuses: [{ id: 'truck_healthy', pct: 10 }],
        penalties: [],
    };
}

// ============================================================================
//                                  THE STORE
// ============================================================================

interface MockMission {
    id: string;
    dbStatus: 'draft' | 'published' | 'archived';
    version: number | null;
    draftVersion: number | null;
    draftTested: boolean;
    editedInCode: boolean;
    owner: { citizenid: string; name: string | null };
    updatedBy: { citizenid: string; name: string | null };
    updatedAt: number;
    lock: { citizenid: string; name: string | null; until: number } | null;
    draft: BuilderDefinition | null;
    published: BuilderDefinition | null;
    backups: number[];
    publishedAt: number | null;
    publishedBy: string | null;
}

const JANE = { citizenid: 'SUP00002', name: 'Jane Roe' };
const MEP = { citizenid: ME, name: ME_NAME };
const store = new Map<string, MockMission>();
function put(m: MockMission) {
    store.set(m.id, m);
}

put({
    id: 'custom_dockside_raid',
    dbStatus: 'published',
    version: 3,
    draftVersion: 4,
    draftTested: true,
    editedInCode: false,
    owner: MEP,
    updatedBy: MEP,
    updatedAt: now() - 3600,
    lock: null,
    draft: docksideRaid(34),
    published: docksideRaid(30),
    backups: [2, 1],
    publishedAt: now() - 86400 * 2,
    publishedBy: 'Sergeant John Doe (SAST, citizenid ABC12345)',
});
put({
    id: 'custom_harbour_sweep',
    dbStatus: 'draft',
    version: null,
    draftVersion: 1,
    draftTested: false,
    editedInCode: false,
    owner: MEP,
    updatedBy: MEP,
    updatedAt: now() - 420,
    lock: { ...MEP, until: now() + 1500 },
    draft: harbourSweep(),
    published: null,
    backups: [],
    publishedAt: null,
    publishedBy: null,
});
put({
    id: 'custom_vinewood_stakeout',
    dbStatus: 'published',
    version: 2,
    draftVersion: 3,
    draftTested: false,
    editedInCode: true,
    owner: JANE,
    updatedBy: { citizenid: 'console', name: null },
    updatedAt: now() - 7200,
    lock: { ...JANE, until: now() + 1140 },
    draft: vinewoodStakeout(),
    published: vinewoodStakeout(),
    backups: [1],
    publishedAt: now() - 7200,
    publishedBy: 'code edit',
});
put({
    id: 'custom_quarry_escort',
    dbStatus: 'archived',
    version: 1,
    draftVersion: null,
    draftTested: false,
    editedInCode: false,
    owner: JANE,
    updatedBy: JANE,
    updatedAt: now() - 86400 * 9,
    lock: null,
    draft: null,
    published: quarryEscort(),
    backups: [],
    publishedAt: now() - 86400 * 20,
    publishedBy: 'Lieutenant Jane Roe (FIB, citizenid SUP00002)',
});

if (EMPTY) store.clear();
if (EDGE) {
    const long = 'Operation Nightfall at the Terminal Island Container Yard (North)';
    const d = docksideRaid();
    put({
        id: 'custom_operation_nightfall_at_the_ter',
        dbStatus: 'published',
        version: 12,
        draftVersion: 13,
        draftTested: false,
        editedInCode: true,
        owner: { citizenid: 'XYZ98765', name: null },
        updatedBy: { citizenid: 'console', name: null },
        updatedAt: now() - 60,
        lock: { citizenid: 'XYZ98765', name: null, until: now() + 600 },
        draft: {
            ...d,
            id: 'custom_operation_nightfall_at_the_ter',
            label: long.slice(0, 64),
            locations: d.locations.map((l, i) => ({
                ...l,
                label: `${'Very long location label that keeps going and going '.slice(0, 60)} ${i + 1}`,
            })),
        },
        published: { ...d, id: 'custom_operation_nightfall_at_the_ter', label: long.slice(0, 64) },
        backups: [11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1],
        publishedAt: now() - 3600,
        publishedBy: 'code edit',
    });
    put({
        id: 'custom_new_patrol_mission',
        dbStatus: 'draft',
        version: null,
        draftVersion: 1,
        draftTested: false,
        editedInCode: false,
        owner: MEP,
        updatedBy: MEP,
        updatedAt: now() - 5,
        lock: { ...MEP, until: now() + 1790 },
        draft: {
            id: 'custom_new_patrol_mission',
            label: 'New Patrol mission',
            description: '',
            type: 'patrol',
            departments: [],
            minOfficers: 1,
            maxOfficers: 4,
            difficulty: 2,
            timeLimit: 600,
            startTimeout: 600,
            cooldown: 1200,
            vehiclePenalties: true,
            locations: [{ label: 'Location 1' }],
            objectives: [],
            scaling: [],
            items: [],
            bonuses: [],
            penalties: [],
        },
        published: null,
        backups: [],
        publishedAt: null,
        publishedBy: null,
    });
}

const BUILTINS: BuilderBuiltinEntry[] = [
    ['armored_truck_escort', 'Armored Truck Escort', 'tactical'],
    ['beat_patrol', 'Beat Patrol', 'patrol'],
    ['bomb_disposal', 'Bomb Disposal', 'tactical'],
    ['business_check', 'Business Check', 'patrol'],
    ['evoc_course', 'EVOC Course', 'training'],
    ['gang_shootout', 'Gang Shootout', 'tactical'],
    ['hostage_rescue', 'Hostage Rescue', 'tactical'],
    ['manhunt', 'Manhunt', 'investigation'],
    ['prison_break', 'Prison Break', 'tactical'],
    ['pursuit_sim', 'Pursuit Sim', 'training'],
    ['stolen_vehicle_takedown', 'Stolen Vehicle Takedown', 'investigation'],
    ['street_race_bust', 'Street Race Bust', 'patrol'],
    ['warrant_service', 'Warrant Service', 'investigation'],
    ['weekly_boss_kingpin', 'Weekly Boss: Kingpin', 'tactical'],
].map(([id, label, type]) => ({ id, label, type, source: 'builtin' as const, readOnly: true as const }));

// ============================================================================
//                                  VALIDATION
// ============================================================================
// A subset of the server guardrails, enough for the screens.

function dist2d(a: Vec3, b: Vec3) {
    return Math.hypot(a.x - b.x, a.y - b.y);
}

function validate(def: BuilderDefinition): BuilderError[] {
    const errors: BuilderError[] = [];
    const add = (path: string, key: string, vars: Record<string, string | number> = {}) =>
        errors.push({ path, key, vars, message: tr(key, vars) });
    if (!def.label?.trim() || def.label.length > 64) add('label', 'builder.error.label', { max: 64 });
    if (!MISSION_TYPES.some(t => t.key === def.type)) add('type', 'builder.error.type_required');
    if (!(def.timeLimit >= 120 && def.timeLimit <= 1200))
        add('timeLimit', 'builder.error.time_limit', { min: 2, max: 20 });
    if (!(def.minOfficers >= 1 && def.maxOfficers <= 4 && def.minOfficers <= def.maxOfficers))
        add('maxOfficers', 'builder.error.officers', { min: 1, max: 4 });
    if (!def.objectives?.length) add('objectives', 'builder.error.no_objectives');
    if ((def.objectives?.length ?? 0) > 6) add('objectives', 'builder.error.max_blocks', { max: 6 });
    const locs = def.locations ?? [];
    if (locs.length < 3) add('locations', 'builder.error.min_locations', { min: 3, have: locs.length });
    locs.forEach((l, i) => {
        if (!l.start) add(`locations.${i + 1}.start`, 'builder.error.start_missing', { location: i + 1 });
        for (let j = 0; j < i; j++) {
            const a = locs[j].start?.coords,
                b = l.start?.coords;
            if (a && b && dist2d(a, b) < 100)
                add(`locations.${i + 1}.start`, 'builder.error.location_gap', { a: j + 1, b: i + 1, min: 100 });
        }
    });
    let armed = 0;
    def.objectives?.forEach((o, i) => {
        if (o.block === 'hostile_waves' && Array.isArray(o.waves))
            armed += (o.waves as number[]).reduce((s, n) => s + n, 0);
        if (!(o.minSeconds >= 1)) add(`objectives.${i + 1}.minSeconds`, 'builder.error.min_seconds', { n: i + 1 });
        const key = typeof o.points === 'string' ? o.points : typeof o.spawns === 'string' ? o.spawns : null;
        if (key)
            locs.forEach((l, li) => {
                if (!l[key])
                    add(`locations.${li + 1}.${key}`, 'builder.error.point_missing', {
                        key,
                        location: li + 1,
                        n: i + 1,
                    });
            });
    });
    if (armed > 40) add('objectives', 'builder.error.armed_budget', { max: 40, have: armed });
    const checkBonus = (list: BuilderBonusEntry[], kind: 'bonuses' | 'penalties') =>
        list.forEach((b, i) => {
            const opt = BONUSES.find(x => x.id === b.id);
            if (!opt) return add(`${kind}.${i + 1}`, 'builder.error.bonus_unknown', { id: b.id });
            if (opt.kind === 'pct' && !((b.pct ?? 0) > 0 && (b.pct ?? 0) <= 25))
                add(`${kind}.${i + 1}.pct`, 'builder.error.bonus_cap_pct', { bonus: b.id, max: 25 });
            if (opt.kind === 'points' && Math.abs(b.points ?? 0) > 50)
                add(`${kind}.${i + 1}.points`, 'builder.error.bonus_cap_points', { bonus: b.id, max: 50 });
        });
    checkBonus(def.bonuses ?? [], 'bonuses');
    checkBonus(def.penalties ?? [], 'penalties');
    (def.items ?? []).forEach((it, i) => {
        const n = it.name.toLowerCase();
        if (n === 'armour' || n === 'bandage' || n.startsWith('ammo-') || n.startsWith('weapon_'))
            add(`items.${i + 1}.name`, 'builder.error.item_forbidden', { name: it.name });
    });
    return errors;
}

function armedOf(def: BuilderDefinition) {
    return (def.objectives ?? []).reduce(
        (s, o) =>
            s +
            (o.block === 'hostile_waves' && Array.isArray(o.waves)
                ? (o.waves as number[]).reduce((a, n) => a + n, 0)
                : 0),
        0,
    );
}

// ============================================================================
//                                    VIEWS
// ============================================================================

function lockView(m: MockMission): BuilderLock | null {
    if (!m.lock || m.lock.until <= now()) return null;
    return {
        citizenid: m.lock.citizenid,
        name: m.lock.name,
        secondsLeft: m.lock.until - now(),
        mine: m.lock.citizenid === ME,
    };
}

function entry(m: MockMission): BuilderListEntry {
    const admin = isAdminView();
    const def = m.draft ?? m.published!;
    const mine = m.owner.citizenid === ME;
    const lock = lockView(m);
    const lockedByOther = !!lock && !lock.mine;
    const canEdit = (mine || admin) && !lockedByOther && m.dbStatus !== 'archived';
    return {
        id: m.id,
        label: def.label,
        type: def.type,
        source: 'custom',
        status:
            m.dbStatus === 'archived'
                ? 'archived'
                : m.dbStatus === 'published'
                  ? 'published'
                  : m.draftTested
                    ? 'tested'
                    : 'draft',
        dbStatus: m.dbStatus,
        version: m.version,
        draftVersion: m.draftVersion,
        hasDraft: !!m.draft,
        draftTested: m.draftTested,
        editedInCode: m.editedInCode,
        filePath:
            m.version == null
                ? null
                : m.dbStatus === 'archived'
                  ? `missions/custom/archived/${m.id}.lua`
                  : `missions/custom/${m.id}.lua`,
        owner: { ...m.owner, mine },
        updatedBy: m.updatedBy,
        updatedAt: m.updatedAt,
        lock,
        requiredTier: tierFor(def.maxOfficers),
        can: {
            edit: canEdit,
            publish: (mine || admin) && !!m.draft && !lockedByOther,
            archive: (mine || admin) && m.dbStatus === 'published',
            restore: (mine || admin) && m.dbStatus === 'archived',
            rollback: admin && m.dbStatus === 'published' && (m.version ?? 0) > 1,
            breakLock: admin && lockedByOther,
            discard: canEdit && !!m.draft,
        },
    };
}

function record(m: MockMission): BuilderRecord {
    const e = entry(m);
    const def = clone(m.draft ?? m.published!);
    return {
        ...e,
        definition: def,
        publishedDefinition: m.published ? clone(m.published) : null,
        readOnly: !e.can.edit,
        errors: validate(def),
        armed: armedOf(def),
        backups: m.backups,
        publishedAt: m.publishedAt,
        publishedBy: m.publishedBy,
    };
}

function builtinRecord(id: string): BuilderRecord | null {
    const b = BUILTINS.find(x => x.id === id);
    if (!b) return null;
    const def = {
        ...docksideRaid(),
        id: b.id,
        label: b.label,
        type: b.type,
        description: `${b.label} (built-in mission, read-only).`,
    };
    const none = {
        edit: false,
        publish: false,
        archive: false,
        restore: false,
        rollback: false,
        breakLock: false,
        discard: false,
    };
    return {
        id: b.id,
        label: b.label,
        type: b.type,
        source: 'builtin',
        status: 'published',
        dbStatus: 'published',
        version: null,
        draftVersion: null,
        hasDraft: false,
        draftTested: false,
        editedInCode: false,
        filePath: `missions/builtin/${b.id}.lua`,
        owner: null,
        updatedBy: null,
        updatedAt: 0,
        lock: null,
        requiredTier: tierFor(def.maxOfficers),
        can: none,
        definition: def,
        publishedDefinition: null,
        readOnly: true,
        errors: [],
        armed: armedOf(def),
        backups: [],
        publishedAt: null,
        publishedBy: null,
    };
}

function need(id: unknown): MockMission {
    if (typeof id !== 'string') throw new Error('err.invalid_payload');
    const m = store.get(id);
    if (!m) {
        if (BUILTINS.some(b => b.id === id)) throw new Error('err.builder_read_only');
        throw new Error('err.builder_unknown_mission');
    }
    return m;
}

function takeLock(m: MockMission) {
    const lock = lockView(m);
    if (lock && !lock.mine) throw new Error('err.builder_locked');
    m.lock = { ...MEP, until: now() + 30 * 60 };
}

function slug(label: string) {
    return (
        label
            .toLowerCase()
            .replace(/[^a-z0-9]+/g, '_')
            .replace(/^_+|_+$/g, '')
            .slice(0, 30)
            .replace(/_$/, '') || 'mission'
    );
}
function uniqueId(label: string, current?: string) {
    const base = `custom_${slug(label)}`;
    for (let n = 1; n < 100; n++) {
        const id = n === 1 ? base : `${base}_${n}`;
        if (id === current || (!store.has(id) && !BUILTINS.some(b => b.id === id))) return id;
    }
    throw new Error('err.internal');
}

const push = (event: string, id?: string, extra: Record<string, unknown> = {}) =>
    emitDebug('push', { topic: 'builder', data: { event, id, by: ME_NAME, ...extra } }, 50);

// ============================================================================
//                                  CALLBACKS
// ============================================================================

reg('request', 'builder:list', () => ({
    missions: [...store.values()].sort((a, b) => b.updatedAt - a.updatedAt).map(entry),
    builtins: BUILTINS,
    me: ME,
    serverTime: now(),
}));

reg('request', 'builder:get', (args: { id?: string }) => {
    const m = typeof args?.id === 'string' ? store.get(args.id) : undefined;
    if (m) return record(m);
    const b = typeof args?.id === 'string' ? builtinRecord(args.id) : null;
    if (b) return b;
    throw new Error('err.builder_unknown_mission');
});

reg('request', 'builder:config', () => buildConfig());

// ============================================================================
//                                   ACTIONS
// ============================================================================

function newDraft(id: string, label: string, def: BuilderDefinition): MockMission {
    const m: MockMission = {
        id,
        dbStatus: 'draft',
        version: null,
        draftVersion: 1,
        draftTested: false,
        editedInCode: false,
        owner: MEP,
        updatedBy: MEP,
        updatedAt: now(),
        lock: { ...MEP, until: now() + 30 * 60 },
        draft: { ...def, id, label },
        published: null,
        backups: [],
        publishedAt: null,
        publishedBy: null,
    };
    put(m);
    push('changed', id);
    return m;
}

reg('action', 'server:builder:create', (p: { type?: string; label?: string }) => {
    const type = MISSION_TYPES.find(t => t.key === p?.type);
    if (!type) throw new Error('err.builder_bad_type');
    const label = p.label?.trim() || tr('builder.default_label', { type: type.label });
    const id = uniqueId(label);
    const def: BuilderDefinition = {
        id,
        label,
        description: '',
        type: type.key,
        departments: [],
        minOfficers: 1,
        maxOfficers: 4,
        difficulty: 2,
        timeLimit: 600,
        startTimeout: 600,
        cooldown: 1200,
        vehiclePenalties: true,
        locations: [{ label: tr('builder.location_default', { n: 1 }) }],
        objectives: [],
        scaling: [],
        items: [],
        bonuses: [],
        penalties: [],
    };
    return { id, record: record(newDraft(id, label, def)) };
});

reg('action', 'server:builder:duplicate', (p: { id?: string }) => {
    const m = typeof p?.id === 'string' ? store.get(p.id) : undefined;
    const source = m ? clone(m.draft ?? m.published!) : builtinRecord(String(p?.id))?.definition;
    if (!source) throw new Error('err.builder_unknown_mission');
    const label = tr('builder.copy_label', { label: source.label }).slice(0, 64);
    const id = uniqueId(label);
    return { id, record: record(newDraft(id, label, source)) };
});

reg('action', 'server:builder:lock', (p: { id?: string }) => {
    const m = need(p?.id);
    if (m.dbStatus === 'archived') throw new Error('err.builder_read_only');
    takeLock(m);
    return { id: m.id, lock: lockView(m) };
});

reg('action', 'server:builder:unlock', (p: { id?: string }) => {
    const m = need(p?.id);
    if (m.lock?.citizenid === ME) m.lock = null;
    return { id: m.id };
});

function store_(p: { id?: string; definition?: BuilderDefinition }, explicit: boolean) {
    const m = need(p?.id);
    if (m.dbStatus === 'archived') throw new Error('err.builder_read_only');
    if (!p.definition || typeof p.definition !== 'object') throw new Error('err.invalid_payload');
    takeLock(m);
    const before = JSON.stringify(m.draft);
    const def = clone(p.definition);
    let previousId: string | null = null;
    if (explicit && m.version == null) {
        const next = uniqueId(def.label || m.id, m.id);
        if (next !== m.id) {
            store.delete(m.id);
            previousId = m.id;
            m.id = next;
            put(m);
        }
    }
    def.id = m.id;
    if (!m.draftVersion) m.draftVersion = (m.version ?? 0) + 1;
    if (JSON.stringify(def) !== before) m.draftTested = false;
    m.draft = def;
    m.updatedAt = now();
    m.updatedBy = MEP;
    const base = { id: m.id, version: m.draftVersion, savedAt: now(), draftTested: m.draftTested, lock: lockView(m) };
    if (!explicit) return base;
    const errors = validate(def);
    push('changed', m.id, { previousId });
    return { ...base, previousId, errors, valid: errors.length === 0 };
}

reg('action', 'server:builder:save', p => store_(p, true));
reg('action', 'server:builder:autosave', p => store_(p, false));

reg('action', 'server:builder:validate', (p: { id?: string; definition?: BuilderDefinition }) => {
    const m = need(p?.id);
    const def = p.definition ?? m.draft ?? m.published!;
    const errors = validate(def);
    return {
        valid: errors.length === 0,
        errors,
        armed: armedOf(def),
        maxHostiles: 40,
        requiredTier: tierFor(def.maxOfficers),
    };
});

reg('action', 'server:builder:test', (p: { id?: string; tier?: string; location?: number | 'random' }) => {
    const m = need(p?.id);
    if (!m.draft) throw new Error('err.builder_no_draft');
    const required = tierFor(m.draft.maxOfficers);
    const tier = p.tier ?? required;
    if (!TIERS.some(t => t.name === tier)) throw new Error('err.builder_bad_tier');
    const location = p.location ?? 1;
    if (location !== 'random' && !(location >= 1 && location <= m.draft.locations.length))
        throw new Error('err.builder_bad_location');
    // Browser mode: the test "passes" a few seconds later (CP.Builder.onDraftTested in game).
    const version = m.draftVersion;
    setTimeout(() => {
        const idx = (n: string) => TIERS.findIndex(t => t.name === n);
        if (m.draftVersion === version && idx(tier) >= idx(required)) m.draftTested = true;
        emitDebug('push', { topic: 'builder', data: { event: 'tested', id: m.id } });
    }, 2500);
    return { id: m.id, version: m.draftVersion, tier, location, requiredTier: required };
});

reg('action', 'server:builder:publish', (p: { id?: string }) => {
    const m = need(p?.id);
    const lock = lockView(m);
    if (lock && !lock.mine) throw new Error('err.builder_locked');
    if (!m.draft) throw new Error('err.builder_no_draft');
    if (validate(m.draft).length) throw new Error('err.builder_invalid');
    if (!m.draftTested) throw new Error('err.builder_not_tested');
    const backup = m.version != null ? `missions/custom/${m.id}.v${m.version}.lua.bak` : null;
    if (m.version != null) m.backups = [m.version, ...m.backups];
    m.version = m.draftVersion ?? (m.version ?? 0) + 1;
    m.published = m.draft;
    m.draft = null;
    m.draftVersion = null;
    m.draftTested = false;
    m.dbStatus = 'published';
    m.editedInCode = false;
    m.lock = null;
    m.updatedAt = now();
    m.publishedAt = now();
    m.publishedBy = `Sergeant ${ME_NAME} (SAST, citizenid ${ME})`;
    push('published', m.id);
    return { id: m.id, version: m.version, filePath: `missions/custom/${m.id}.lua`, backup };
});

reg('action', 'server:builder:archive', (p: { id?: string }) => {
    const m = need(p?.id);
    if (m.dbStatus !== 'published') throw new Error('err.builder_not_published');
    m.dbStatus = 'archived';
    m.updatedAt = now();
    push('archived', m.id);
    return { id: m.id, filePath: `missions/custom/archived/${m.id}.lua` };
});

reg('action', 'server:builder:restore', (p: { id?: string }) => {
    const m = need(p?.id);
    if (m.dbStatus !== 'archived') throw new Error('err.builder_not_archived');
    m.dbStatus = 'published';
    m.updatedAt = now();
    push('restored', m.id);
    return { id: m.id, filePath: `missions/custom/${m.id}.lua` };
});

reg('action', 'server:builder:rollback', (p: { id?: string }) => {
    if (!isAdminView()) throw new Error('err.no_permission');
    const m = need(p?.id);
    if (m.dbStatus !== 'published' || m.version == null) throw new Error('err.builder_not_published');
    const from = m.backups.find(v => v < (m.version ?? 0));
    if (from == null) throw new Error('err.builder_no_backup');
    m.backups = [m.version, ...m.backups];
    m.version += 1;
    if (m.draftVersion != null) m.draftVersion = m.version + 1;
    m.editedInCode = false;
    m.updatedAt = now();
    push('rolledBack', m.id);
    return { id: m.id, version: m.version, fromVersion: from };
});

reg('action', 'server:builder:breakLock', (p: { id?: string }) => {
    if (!isAdminView()) throw new Error('err.no_permission');
    const m = need(p?.id);
    const previous = m.lock ? { citizenid: m.lock.citizenid, name: m.lock.name } : null;
    m.lock = null;
    push('lockBroken', m.id);
    return { id: m.id, previous };
});

reg('action', 'server:builder:discardDraft', (p: { id?: string }) => {
    const m = need(p?.id);
    const lock = lockView(m);
    if (lock && !lock.mine) throw new Error('err.builder_locked');
    if (!m.draft) throw new Error('err.builder_no_draft');
    let deleted = false;
    if (m.version == null) {
        store.delete(m.id);
        deleted = true;
    } else {
        m.draft = null;
        m.draftVersion = null;
        m.draftTested = false;
        m.lock = null;
    }
    push(deleted ? 'deleted' : 'changed', m.id);
    return { id: m.id, deleted };
});

// ============================================================================
//                            BUILDER CLIENT ACTIONS
// ============================================================================
// Fallbacks; the builder client's mock file wins.

let pending: BuilderClientResult | null = null;

function deliver(result: BuilderClientResult, delay: number) {
    setTimeout(() => {
        pending = result;
        emitDebug('push', { topic: 'builder', data: { event: 'clientResult', id: result.missionId, result } });
    }, delay);
}

registerMock(
    'client',
    'builderPlace',
    (p: {
        missionId: string;
        location: number;
        key: string;
        heading: boolean;
        multiple: boolean;
        points?: (Vec3 | Vec4)[];
        start?: Vec3 | null;
        kind?: string;
    }) => {
        const base = p.start ?? v3(1017.52, -3108.44, 5.9);
        const count = p.multiple ? 4 : 1;
        const pts =
            p.kind === 'start'
                ? [v3(base.x, base.y, base.z)]
                : Array.from({ length: count }, (_, i) =>
                      p.heading
                          ? v4(base.x + 35 + i * 2.5, base.y + 40, base.z, 90)
                          : v3(base.x + 35 + i * 2.5, base.y + 40, base.z),
                  );
        deliver(
            {
                kind: 'placement',
                missionId: p.missionId,
                location: p.location,
                key: p.key,
                points: [...(p.points ?? []), ...pts],
                radius: p.kind === 'start' ? 60 : undefined,
                cancelled: false,
            },
            1500,
        );
        return { started: true };
    },
    { fallback: true },
);

registerMock(
    'client',
    'builderRecord',
    (p: { missionId: string; location: number; key: string; stops: boolean; loop: boolean }) => {
        const points = Array.from({ length: 18 }, (_, i) => v3(1017 + i * 80, -3108 + Math.sin(i / 3) * 60, 5.9));
        if (p.loop) points.push(v3(1022, -3100, 5.9));
        const length = Math.round(
            points.slice(1).reduce((s, q, i) => s + Math.hypot(q.x - points[i].x, q.y - points[i].y), 0),
        );
        deliver(
            {
                kind: 'recording',
                missionId: p.missionId,
                location: p.location,
                key: p.key,
                cancelled: false,
                route: { points, stops: p.stops ? [{ at: 9, wait: 20 }] : [], loop: p.loop || undefined },
                length,
                rejected: 3,
                rejectedSamples: [v3(1180, -3060, 5.9), v3(1205, -3071, 5.9), v3(1230, -3080, 5.9)],
                unreachable: [],
            },
            2000,
        );
        return { started: true };
    },
    { fallback: true },
);

registerMock(
    'client',
    'builderTestDrive',
    (p: { missionId: string; location: number; key: string }) => {
        deliver(
            {
                kind: 'testdrive',
                missionId: p.missionId,
                location: p.location,
                key: p.key,
                completed: true,
                failed: [11],
                cancelled: false,
            },
            2500,
        );
        return { started: true };
    },
    { fallback: true },
);

registerMock(
    'client',
    'builderResult',
    () => {
        const r = pending;
        pending = null;
        return r;
    },
    { fallback: true },
);

registerMock('client', 'builderCancel', () => ({ cancelled: pending !== null }), { fallback: true });
registerMock('client', 'builderWaypoint', () => ({ ok: true }), { fallback: true });
