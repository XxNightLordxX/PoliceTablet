// What a press of Abandon on Active Mission does (officer option abandonConfirm). With the option on (as
// before) it opens the dialog. Off: the first press arms the button ("Click again to abandon") for ABANDON_ARM_MS, a
// second press while armed abandons. An abandon still costs the type cooldown (Config.Limits.abandonCooldown).

// What a press of Abandon on Active Mission does (officer option abandonConfirm): with the option on, the
// dialog as before; off, the first press arms the button ("Click again to abandon") for 3 s and a second press while
// armed abandons. Walk: abandonPress.walk.ts.

export const ABANDON_ARM_MS = 3000;

export type AbandonPress = 'dialog' | 'arm' | 'abandon';

export function abandonPress(confirm: boolean, armed: boolean): AbandonPress {
    if (confirm) return 'dialog';
    return armed ? 'abandon' : 'arm';
}
