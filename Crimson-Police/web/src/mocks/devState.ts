// Mutable dev-mode state shared by core.mock.ts and the DevPanel (browser mode only).

export type DevDept = 'sast' | 'fib' | 'bcso';

export const devState = {
    department: 'sast' as DevDept,
    // getRun returns a sample run while true (drives the pinned run bar).
    runActive: false,
};
