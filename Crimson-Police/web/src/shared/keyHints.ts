// Key hints (officer option keyHints): the key bound to a Crimson-Police key mapping, named on the ready
// check banner ("or press K") and the contact HUD line. The client action getKeyHints answers only the bound keys
// with a text label, and none while the officer keeps the hints off on this PC.

// useKeyHint(name): the label of the key bound to the ready, contact, tablet or Dispatch key mapping, from
// the client action getKeyHints, or null when the officer turned Key hints off on this PC or the key is not bound
// with a text label. ReadyCheckBanner says "Or press K."; the contact HUD line names the contact key.

import { useEffect, useState } from 'react';
import { clientAction } from './nui';
import { useOption } from './options';

export type KeyHintName = 'tablet' | 'dispatch' | 'ready' | 'contact';

// The key label to show ('K'), or null: hints off, the key not bound, or no answer.
export function useKeyHint(name: KeyHintName): string | null {
    const on = useOption('keyHints') !== false;
    const [key, setKey] = useState<string | null>(null);
    useEffect(() => {
        if (!on) {
            setKey(null);
            return;
        }
        let live = true;
        void clientAction<{ keys?: Partial<Record<KeyHintName, string>> }>('getKeyHints').then(res => {
            const label = res.ok ? res.data?.keys?.[name] : undefined;
            if (live) setKey(typeof label === 'string' && label !== '' ? label : null);
        });
        return () => {
            live = false;
        };
    }, [on, name]);
    return on ? key : null;
}
