// Tablet access shapes (modules/tablet admin:getTabletAccess): the ways, the mission desks and each department's
// personal accents, for Admin UI → Departments.

export interface DeskView {
    index: number;
    label: string;
    coords: { x: number; y: number; z: number };
    size: { x: number; y: number; z: number };
    rotation: number;
    // null = every department
    departments: string[] | null;
    prop: string | null;
}

export interface TabletAccessView {
    ways: { command: boolean; keybind: boolean; item: boolean; desk: boolean; requireItem: boolean };
    item: string | null;
    deskDistance: number;
    desks: DeskView[];
    accents: Record<string, { colour: string; level: number | null }[]>;
    appearances: string[];
}
