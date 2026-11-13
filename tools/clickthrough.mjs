// node tools/clickthrough.mjs [outDir] [only] · the click-through of every tablet in a real browser (WF5F).
// Serves the built web UI (Crimson-Police/web/dist, run npm run build first) in its browser mock mode, opens the
// Officer, Supervisor, Admin and criminal tablets in Chromium (Playwright) and clicks every screen, every tab and
// every button of each screen, and checks each dialog a button opens (its text and its buttons) before closing it.
// It fails on a console error or page error, a screen that crashed (the error card), a blank screen, a button that
// cannot be clicked (something else is on top of it), two buttons that overlap, or text that is a locale key (a
// missing string shows its key).
// The "world" pass opens the in-world screens with no tablet (?hud=<kind> and ?result=<kind>: the mission HUD, its
// contact card and test controls, the result card and its debrief) in a 1280x720 window: the same checks, the HUD
// column inside the window, and each button of the result card clicked.
// Every screen also stays inside the window: the tablet frame on screen, no sideways page scroll, and no button,
// heading, table head, tab or menu entry whose text is cut off (scrollWidth over clientWidth with its overflow hidden
// and no ellipsis). A guided tour a button starts (Settings > Tours > Start) is checked to show and then skipped, so
// its card never covers the later screens; a dialog opened while a tour runs must have its buttons on top (the tour
// steps aside). A dialog that Escape and its close button cannot close is a failure.
// Sizes: the full sweep runs the tablets at 1600x900 and the world at 1280x720; then every size of CP_CT_VIEWPORTS
// (default 1280x720,1920x1080,3840x2160) gets a nav pass (each screen opened and checked, no button clicks) of every
// tablet and the world, plus a phone (390x844) for the world and the criminal tablet. CP_CT_VIEWPORTS=none skips them.
// Screenshots go to outDir (default: a fresh folder in the system temp folder), never into the repo.
// `only` (officer, supervisor, admin, crimtab or world) runs one part; `tour` runs only the tour-under-a-dialog check. Needs Chromium for Playwright (npx playwright
// install chromium once): the opt-in step `tools/check_all.sh clickthrough` (or CP_CLICKTHROUGH=1) and the nightly CI
// job run it. npm run clickthrough (in Crimson-Police/web) builds and runs it.

import { mkdtempSync, mkdirSync, readFileSync, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const WEB = join(ROOT, 'Crimson-Police', 'web');
const webRequire = createRequire(join(WEB, 'package.json'));
const { preview } = await import(webRequire.resolve('vite'));
let playwright;
try {
    playwright = createRequire(import.meta.url)('playwright');
} catch {
    playwright = webRequire('playwright');
}

const OUT = process.argv[2] || mkdtempSync(join(tmpdir(), 'clickthrough-'));
const ONLY = process.argv[3] || '';
mkdirSync(OUT, { recursive: true });

// Every locale key, and the first parts they start with: text that is one of them, or looks like one, is a key the
// UI shows instead of its string.
const KEYS = new Set();
for (const f of readdirSync(join(ROOT, 'Crimson-Police', 'locales', 'parts'))) {
    if (!f.endsWith('.json')) continue;
    for (const k of Object.keys(JSON.parse(readFileSync(join(ROOT, 'Crimson-Police', 'locales', 'parts', f), 'utf8'))))
        KEYS.add(k);
}
const HEADS = [...new Set([...KEYS].map(k => k.split('.')[0]))].filter(h => h.length > 1);
const KEY_RE = new RegExp(`(?:^|[\\s(])((?:${HEADS.join('|')})\\.[a-z0-9_]+(?:\\.[a-z0-9_]+)*)(?=$|[\\s),:])`, 'g');

const BLANK_PNG = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    'base64',
);
const failures = [];
const covered = [];
let shots = 0;
const fail = (where, what) => {
    const line = `${where}: ${what}`;
    if (!failures.includes(line)) failures.push(line);
};

const server = await preview({
    root: WEB,
    logLevel: 'error',
    preview: { port: 4179, strictPort: false, host: '127.0.0.1', open: false },
});
const base = server.resolvedUrls.local[0];

const browser = await playwright.chromium.launch();
const TABLETS = [
    { ui: 'officer', frame: '.cp-tablet', main: 'main.cp-main', nav: '.cp-nav-item' },
    { ui: 'supervisor', frame: '.cp-tablet', main: 'main.cp-main', nav: '.cp-nav-item' },
    { ui: 'admin', frame: '.cp-admin', main: 'main.cp-main', nav: '.cp-nav-item' },
    { ui: 'crimtab', frame: '.crim-frame', main: '.crim-body', nav: '.crim-tab' },
];

// the samples of the world pass (src/mocks/samples.ts SampleHudKind, the ?result= kinds of src/mocks/DevPanel.tsx)
const HUD_KINDS = ['progress', 'offroute', 'test'];
const RESULT_KINDS = ['completed', 'failed', 'test', 'flagged'];

// Buttons nobody should click in a sweep: they close the tablet or leave it (checked as shown and clickable only).
const LEAVES = /^(close|close tablet|switch to|log out)$/i;

// The full sweep's sizes, and the extra sizes of the nav passes (CP_CT_VIEWPORTS: WxH,WxH,... or none).
const SWEEP_SIZE = { width: 1600, height: 900 };
const WORLD_SIZE = { width: 1280, height: 720 };
const PHONE = { width: 390, height: 844 };
const VIEWPORTS = (process.env.CP_CT_VIEWPORTS ?? '1280x720,1920x1080,3840x2160')
    .split(',')
    .map(v => v.trim().match(/^(\d+)x(\d+)$/))
    .filter(Boolean)
    .map(m => ({ width: Number(m[1]), height: Number(m[2]) }));
const sizeName = s => `${s.width}x${s.height}`;

try {
    for (const tab of TABLETS) {
        if (ONLY && tab.ui !== ONLY) continue;
        await sweep(tab);
    }
    if (!ONLY || ONLY === 'world') await world(WORLD_SIZE);
    if (!ONLY || ONLY === 'admin' || ONLY === 'tour') await tourOverDialog();
    for (const size of VIEWPORTS) {
        for (const tab of TABLETS) {
            if (ONLY && tab.ui !== ONLY) continue;
            await navPass(tab, size);
        }
        if (!ONLY || ONLY === 'world') await world(size);
    }
    if (VIEWPORTS.length) {
        if (!ONLY || ONLY === 'crimtab') await navPass(TABLETS[3], PHONE);
        if (!ONLY || ONLY === 'world') await world(PHONE);
    }
} finally {
    await browser.close();
    await new Promise(r => server.httpServer.close(r));
}

console.log(`screens covered (${covered.length}):`);
for (const c of covered) console.log(`  ${c}`);
console.log(`screenshots: ${shots} in ${OUT}`);
if (failures.length) {
    console.log(`FAIL ${failures.length} defect(s):`);
    for (const f of failures) console.log(`  FAIL ${f}`);
    process.exit(1);
}
console.log('ok   clickthrough: every screen, tab, dialog and button passed');

async function sweep(tab) {
    const page = await browser.newPage({ viewport: SWEEP_SIZE });
    // offline like the game may be: a picture from the internet (a mock officer photo) gets a blank one
    await page.route(
        url => !url.href.startsWith(base),
        route => route.fulfill({ contentType: 'image/png', body: BLANK_PNG }),
    );
    let where = `${tab.ui}: load`;
    page.on('console', m => {
        if (m.type() === 'error') fail(where, `console error: ${m.text().slice(0, 300)}`);
    });
    page.on('pageerror', e => fail(where, `page error: ${String(e.message).slice(0, 300)}`));
    // a closed tablet sends close; the mocks answer it, nothing to catch here
    await page.goto(`${base}?ui=${tab.ui}&dev=0&bg=none`);
    const open = async () => {
        if (await page.locator(tab.frame).count()) return;
        await page.goto(`${base}?ui=${tab.ui}&dev=0&bg=none`);
        await page.waitForSelector(tab.frame, { timeout: 8000 });
    };
    try {
        await page.waitForSelector(tab.frame, { timeout: 8000 });
    } catch {
        fail(where, 'the tablet did not open');
        await page.close();
        return;
    }
    await settle(page);
    // the Admin UI folds its rare screens under More: open it, so every screen is in the list
    const unfold = async () => {
        const more = page.locator('.cp-nav-item--more:not(.is-open)');
        if (await more.count()) {
            await more.first().click({ timeout: 3000 });
            await page.waitForTimeout(150);
        }
    };
    await unfold();
    const NAV = `${tab.nav}:not(.cp-nav-item--more)`;
    const labels = await page.locator(NAV).allInnerTexts();
    for (let i = 0; i < labels.length; i++) {
        const screen = labels[i].split('\n')[0].trim() || `#${i}`;
        where = `${tab.ui} > ${screen}`;
        await open();
        const goTo = async () => {
            await open();
            await unfold();
            await page.locator(NAV).nth(i).click({ timeout: 3000 });
            await settle(page);
        };
        try {
            await goTo();
        } catch (e) {
            fail(where, `the screen's menu entry could not be clicked (${String(e.message).split('\n')[0]})`);
            continue;
        }
        await check(page, tab, where, true);
        await shot(page, where);
        const tabs = await page.locator(`${tab.main} [role="tab"]`).allInnerTexts();
        const tabNames = tabs.length ? tabs.map(t => t.split('\n')[0].trim()) : [null];
        for (let j = 0; j < tabNames.length; j++) {
            const here = tabNames[j] ? `${tab.ui} > ${screen} > ${tabNames[j]}` : `${tab.ui} > ${screen}`;
            where = here;
            const goTab = async () => {
                await goTo();
                if (tabNames[j]) {
                    const t = page.locator(`${tab.main} [role="tab"]`).nth(j);
                    if (await t.count()) await t.click();
                    await settle(page);
                }
            };
            try {
                await goTab();
                if (tabNames[j]) {
                    await check(page, tab, here, true);
                    await shot(page, here);
                }
                covered.push(here);
                await clickAll(page, tab, here, goTab, w => (where = w));
            } catch (e) {
                fail(where, `stopped: ${String(e.message).split('\n')[0]}`);
            }
        }
    }
    await page.close();
}

// The in-world screens (src/hud): every sample HUD and result card of the browser mocks (src/mocks/samples.ts) on a
// game screen of that size (1280x720 in the full sweep) with no tablet open (HUD_KINDS, RESULT_KINDS above).
async function world(size) {
    const at = size === WORLD_SIZE ? '' : ` @${sizeName(size)}`;
    const views = [
        ...HUD_KINDS.map(k => ({ name: `hud ${k}`, query: `hud=${k}`, sel: '.cp-hud-column' })),
        ...RESULT_KINDS.map(k => ({ name: `result ${k}`, query: `result=${k}`, sel: '.cp-result' })),
    ];
    for (const v of views) {
        const page = await browser.newPage({ viewport: size });
        await page.route(
            url => !url.href.startsWith(base),
            route => route.fulfill({ contentType: 'image/png', body: BLANK_PNG }),
        );
        const where = `world${at} > ${v.name}`;
        page.on('console', m => {
            if (m.type() === 'error') fail(where, `console error: ${m.text().slice(0, 300)}`);
        });
        page.on('pageerror', e => fail(where, `page error: ${String(e.message).slice(0, 300)}`));
        try {
            await page.goto(`${base}?${v.query}&dev=0&bg=none`);
            try {
                await page.waitForSelector(v.sel, { timeout: 8000 });
            } catch {
                fail(where, `${v.sel} did not show`);
                continue;
            }
            await settle(page);
            const el = page.locator(v.sel).first();
            const text = (await el.innerText()).trim();
            if (text.length < 3) fail(where, 'blank');
            keysIn(text, where);
            await buttonsOk(page, v.sel, where);
            // the HUD column stays on the screen (it scales itself down to fit the height)
            const box = await page.locator('.cp-hud-column').first().boundingBox();
            if (!box) fail(where, 'no HUD column');
            else if (
                box.x < 0 ||
                box.y < 0 ||
                box.x + box.width > size.width + 0.5 ||
                box.y + box.height > size.height + 0.5
            )
                fail(where, `the HUD column leaves the ${sizeName(size)} screen (${JSON.stringify(box)})`);
            await layoutOk(page, v.sel, where);
            await shot(page, where);
            covered.push(where);
            // the extra sizes: the layout only (the full sweep clicks the buttons)
            if (at) continue;
            // each button of the card once (Dismiss and Close last: they close the card)
            const labels = await page
                .locator(`${v.sel} button`)
                .evaluateAll(els => els.map(b => (b.getAttribute('aria-label') || b.innerText || '').trim()));
            const last = l => (/^(dismiss|close)/i.test(l) ? 1 : 0);
            const order = labels.map((l, i) => ({ l, i })).sort((a, b) => last(a.l) - last(b.l));
            for (const { l, i } of order) {
                const b = page.locator(`${v.sel} button`).nth(i);
                if (!(await b.count()) || !(await b.isVisible()) || !(await b.isEnabled())) continue;
                try {
                    await b.click({ timeout: 2000 });
                } catch (e) {
                    fail(`${where} [${l}]`, `could not be clicked (${why(e)})`);
                }
                await settle(page);
                if (await page.locator(v.sel).count()) keysIn((await page.locator(v.sel).first().innerText()).trim(), where);
            }
        } catch (e) {
            fail(where, `stopped: ${String(e.message).split('\n')[0]}`);
        } finally {
            await page.close();
        }
    }
}

// Every visible button of the screen once, in order; the screen is opened again after each.
async function clickAll(page, tab, here, reopen, setWhere) {
    const seen = new Set();
    for (let n = 0; n < 60; n++) {
        const btn = await nextButton(page, tab, seen);
        if (!btn) break;
        const { index, label } = btn;
        seen.add(label);
        const w = `${here} [${label}]`;
        setWhere(w);
        await dismissToasts(page);
        let clicked = false;
        let err = null;
        // a screen still loading can redraw its buttons between the look and the click: find the button again once
        for (let tries = 0; tries < 2 && !clicked; tries++) {
            const at = tries === 0 ? index : await indexOf(page, tab, label);
            if (at < 0) break;
            try {
                await page.locator(`${tab.main} button`).nth(at).click({ timeout: 2000 });
                clicked = true;
            } catch (e) {
                err = e;
                await settle(page);
            }
        }
        if (!clicked) {
            // the tablet closed itself in between (Start test hides it a moment later for the run in the world)
            if (err && (await page.locator(tab.frame).count())) fail(w, `could not be clicked (${why(err)})`);
            await endTour(page, w, false);
            await reopen();
            continue;
        }
        await settle(page);
        if (!(await page.locator(tab.frame).count())) {
            await endTour(page, w, false);
            await reopen();
            continue;
        }
        await check(page, tab, w, false);
        const dialogs = page.locator('[role="dialog"].cp-dialog');
        if (await dialogs.count()) {
            await shot(page, w);
            await checkDialog(page, w);
            await closeDialogs(page, w);
        }
        // a tour this button started (Settings > Tours > Start): it shows, then it is skipped, so its card never
        // covers the screens after it
        await endTour(page, w, true);
        await reopen();
    }
}

// Where the button with that label is now (-1: gone).
async function indexOf(page, tab, label) {
    const labels = await page
        .locator(`${tab.main} button`)
        .evaluateAll(els =>
            els.map(el => (el.getAttribute('aria-label') || el.innerText || el.title || '').trim().split('\n')[0]),
        );
    return labels.findIndex((l, i) => (l || `#${i}`) === label);
}

// The first visible, enabled button of the main area whose label was not clicked yet.
async function nextButton(page, tab, seen) {
    const list = await page.locator(`${tab.main} button`).evaluateAll(els =>
        els.map(el => {
            const r = el.getBoundingClientRect();
            const label = (el.getAttribute('aria-label') || el.innerText || el.title || '').trim().split('\n')[0];
            return {
                label,
                // checkVisibility: not inside a closed <details>, display:none or visibility:hidden
                shown: r.width > 0 && r.height > 0 && el.checkVisibility({ visibilityProperty: true }),
                disabled: el.disabled || el.getAttribute('aria-disabled') === 'true',
                tab: el.getAttribute('role') === 'tab',
            };
        }),
    );
    for (let i = 0; i < list.length; i++) {
        const it = list[i];
        const key = it.label || `#${i}`;
        if (!it.shown || it.disabled || it.tab || seen.has(key) || LEAVES.test(it.label)) continue;
        return { index: i, label: key };
    }
    return null;
}

// The line of Playwright's click log that says why a click did not happen.
function why(e) {
    const lines = String(e.message).split('\n').map(l => l.replace(/\x1b\[[0-9;]*m/g, '').trim());
    const why = /intercepts pointer|outside of the viewport|not visible|not enabled|not stable/;
    const hit = lines.filter(l => why.test(l));
    return (hit.pop() || lines.filter(Boolean).slice(-3).join(' | ')).slice(0, 300);
}

async function settle(page) {
    await page.waitForTimeout(350);
}

async function shot(page, where) {
    shots += 1;
    const name = `${String(shots).padStart(4, '0')}-${where.replace(/[^a-z0-9]+/gi, '_').slice(0, 90)}.png`;
    await page.screenshot({ path: join(OUT, name) });
}

// The screen is not blank, did not crash, shows no locale key, and its buttons are clickable and apart.
async function check(page, tab, where, full) {
    const main = page.locator(tab.main).first();
    if (!(await main.count())) return fail(where, 'no screen area');
    const crashed = page.locator(`${tab.main} .cp-empty--error`);
    if (await crashed.count())
        fail(where, `screen crashed: ${(await crashed.first().innerText()).replace(/\s+/g, ' ')}`);
    const text = (await main.innerText()).trim();
    if (full && text.length < 3) fail(where, 'blank screen');
    keysIn(text, where);
    if (full) await buttonsOk(page, tab.main, where);
    if (full) await layoutOk(page, tab.frame, where);
}

// The frame stays inside the window, the page never scrolls sideways, and no button, heading, table head, tab or
// menu entry has its text cut off (scrollWidth over clientWidth, its overflow not visible, no ellipsis).
async function layoutOk(page, frame, where) {
    const bad = await page.evaluate(sel => {
        const out = [];
        const vw = window.innerWidth;
        const vh = window.innerHeight;
        const root = document.querySelector(sel);
        if (!root) return out;
        const r = root.getBoundingClientRect();
        if (r.left < -1 || r.top < -1 || r.right > vw + 1 || r.bottom > vh + 1)
            out.push(`the frame leaves the ${vw}x${vh} window (${[r.left, r.top, r.right, r.bottom].map(Math.round)})`);
        if (document.documentElement.scrollWidth > vw + 1)
            out.push(`the page scrolls sideways (${document.documentElement.scrollWidth} > ${vw})`);
        for (const el of root.querySelectorAll('button, h1, h2, h3, th, [role="tab"], .cp-nav-item')) {
            if (!el.checkVisibility({ visibilityProperty: true }) || el.clientWidth <= 0) continue;
            const cs = getComputedStyle(el);
            if (el.scrollWidth > el.clientWidth + 2 && cs.overflowX !== 'visible' && cs.textOverflow !== 'ellipsis')
                out.push(
                    `text cut off: <${el.tagName.toLowerCase()}> "${(el.innerText || '').trim().slice(0, 40)}" ` +
                        `(${el.scrollWidth} > ${el.clientWidth})`,
                );
        }
        return out.slice(0, 8);
    }, frame);
    for (const b of bad) fail(where, b);
}

// A guided tour running now: (shows) its card is on screen with its buttons on top, then Skip ends it (else
// Escape). A tour still running after that is a failure.
async function endTour(page, where, shows) {
    const card = page.locator('.cp-tour__card');
    if (!(await card.count())) return;
    if (shows) {
        if (!(await card.first().isVisible())) fail(where, 'the tour it started shows no card');
        else await buttonsOk(page, '.cp-tour__card', `${where} tour card`);
    }
    const skip = card.first().locator('button', { hasText: /^skip$/i });
    if (await skip.count()) await skip.first().click({ timeout: 1000 }).catch(() => undefined);
    for (let k = 0; k < 4 && (await page.locator('.cp-tour').count()); k++) {
        await page.keyboard.press('Escape');
        await page.waitForTimeout(150);
    }
    if (await page.locator('.cp-tour').count()) fail(where, 'the tour could not be ended (Skip and Escape)');
}

// A tour that runs while a dialog opens over it (Admin UI: Settings > Tours > Start, then Leaderboards > Item rewards >
// Deliver now): the dialog's buttons must be on top (the tour steps aside while a dialog is open), and the tour shows again
// once the dialog is closed.
async function tourOverDialog() {
    const tab = TABLETS[2];
    const where = 'admin: a tour running under a dialog';
    const page = await browser.newPage({ viewport: SWEEP_SIZE });
    await page.route(
        url => !url.href.startsWith(base),
        route => route.fulfill({ contentType: 'image/png', body: BLANK_PNG }),
    );
    page.on('pageerror', e => fail(where, `page error: ${String(e.message).slice(0, 300)}`));
    const nav = async name => {
        const more = page.locator('.cp-nav-item--more:not(.is-open)');
        if (await more.count()) await more.first().click({ timeout: 3000 });
        await page.locator(tab.nav, { hasText: new RegExp(`^\\s*${name}\\b`) }).first().click({ timeout: 3000 });
        await settle(page);
    };
    let step = 'open the Admin UI';
    try {
        await page.goto(`${base}?ui=admin&dev=0&bg=none`);
        await page.waitForSelector(tab.frame, { timeout: 8000 });
        await settle(page);
        step = 'Settings > Tours > Start';
        await nav('Settings');
        const tours = page.locator(`${tab.main} [role="tab"]`, { hasText: /^\s*Tours\b/ });
        if (await tours.count()) await tours.first().click({ timeout: 3000 });
        await settle(page);
        await page.locator(`${tab.main} button`, { hasText: /^\s*Start\s*$/ }).first().click({ timeout: 3000 });
        await settle(page);
        if (!(await page.locator('.cp-tour__card').count())) {
            fail(where, 'Settings > Tours > Start showed no tour card');
            return;
        }
        step = 'Leaderboards > Item rewards > Deliver now';
        await nav('Leaderboards');
        const rewards = page.locator(`${tab.main} button`, { hasText: /^\s*Item rewards\s*$/ });
        if (await rewards.count()) await rewards.first().click({ timeout: 3000 });
        await settle(page);
        await page
            .locator(tab.main)
            .getByRole('button', { name: /Deliver now/i })
            .first()
            .click({ timeout: 3000 });
        await settle(page);
        if (!(await page.locator('[role="dialog"].cp-dialog').count())) {
            fail(where, 'Leaderboards > Item rewards > Deliver now opened no dialog');
            return;
        }
        step = 'the dialog';
        await shot(page, where);
        await buttonsOk(page, '[role="dialog"].cp-dialog', `${where} (the dialog)`);
        await closeDialogs(page, where);
        await settle(page);
        if (!(await page.locator('.cp-tour__card').first().isVisible().catch(() => false)))
            fail(where, 'the tour did not come back after the dialog closed');
        await endTour(page, where, false);
        covered.push(where);
    } catch (e) {
        fail(where, `stopped at ${step}: ${why(e)}`);
    } finally {
        await page.close();
    }
}

// One tablet at another window size: every screen of the menu opened and checked (no button clicks).
async function navPass(tab, size) {
    const page = await browser.newPage({ viewport: size });
    await page.route(
        url => !url.href.startsWith(base),
        route => route.fulfill({ contentType: 'image/png', body: BLANK_PNG }),
    );
    let where = `${tab.ui} @${sizeName(size)}: load`;
    page.on('console', m => {
        if (m.type() === 'error') fail(where, `console error: ${m.text().slice(0, 300)}`);
    });
    page.on('pageerror', e => fail(where, `page error: ${String(e.message).slice(0, 300)}`));
    try {
        await page.goto(`${base}?ui=${tab.ui}&dev=0&bg=none`);
        try {
            await page.waitForSelector(tab.frame, { timeout: 8000 });
        } catch {
            fail(where, 'the tablet did not open');
            return;
        }
        await settle(page);
        const more = page.locator('.cp-nav-item--more:not(.is-open)');
        if (await more.count()) await more.first().click({ timeout: 3000 });
        const NAV = `${tab.nav}:not(.cp-nav-item--more)`;
        const labels = await page.locator(NAV).allInnerTexts();
        for (let i = 0; i < labels.length; i++) {
            const screen = labels[i].split('\n')[0].trim() || `#${i}`;
            where = `${tab.ui} @${sizeName(size)} > ${screen}`;
            try {
                await page.locator(NAV).nth(i).click({ timeout: 3000 });
            } catch (e) {
                fail(where, `the screen's menu entry could not be clicked (${why(e)})`);
                continue;
            }
            await settle(page);
            await check(page, tab, where, true);
            if (i === 0) await shot(page, where);
            covered.push(where);
        }
    } catch (e) {
        fail(where, `stopped: ${String(e.message).split('\n')[0]}`);
    } finally {
        await page.close();
    }
}

async function checkDialog(page, where) {
    const d = page.locator('[role="dialog"].cp-dialog').last();
    const text = (await d.innerText()).trim();
    if (text.length < 3) fail(where, 'blank dialog');
    keysIn(text, `${where} dialog`);
    await buttonsOk(page, '[role="dialog"].cp-dialog', `${where} dialog`);
}

function keysIn(text, where) {
    for (const m of text.matchAll(KEY_RE)) {
        const k = m[1];
        // a value that only looks like a key (an e-mail-like id, a file name) is fine when it is not a key shape
        if (KEYS.has(k) || /^[a-z]+\.[a-z0-9_]+(\.[a-z0-9_]+)*$/.test(k)) fail(where, `shows a locale key: ${k}`);
    }
}

// Every visible button has its middle on top (nothing covers it) and no two buttons overlap.
async function buttonsOk(page, scope, where) {
    const bad = await page.evaluate(sel => {
        const out = [];
        const root = [...document.querySelectorAll(sel)].pop();
        if (!root) return out;
        const btns = [...root.querySelectorAll('button')].filter(b => {
            const r = b.getBoundingClientRect();
            return r.width > 0 && r.height > 0 && b.checkVisibility({ visibilityProperty: true });
        });
        const name = b => (b.getAttribute('aria-label') || b.innerText || b.title || '?').trim().split('\n')[0];
        // what of the button shows: its rect cut by every ancestor that clips (overflow not visible), null when
        // nothing of it shows (scrolled out of its list)
        const shownRect = b => {
            const r = b.getBoundingClientRect();
            let { left, top, right, bottom } = r;
            for (let el = b.parentElement; el && el !== document.documentElement; el = el.parentElement) {
                const cs = getComputedStyle(el);
                if (cs.overflowX === 'visible' && cs.overflowY === 'visible') continue;
                const c = el.getBoundingClientRect();
                if (cs.overflowX !== 'visible') {
                    left = Math.max(left, c.left);
                    right = Math.min(right, c.right);
                }
                if (cs.overflowY !== 'visible') {
                    top = Math.max(top, c.top);
                    bottom = Math.min(bottom, c.bottom);
                }
            }
            return right - left > 0 && bottom - top > 0 ? { left, top, right, bottom } : null;
        };
        // overlap first, before anything scrolls (rects of one moment, as far as they show)
        const rects = btns.map(b => [b, shownRect(b)]).filter(([, r]) => r);
        for (let i = 0; i < rects.length; i++)
            for (let j = i + 1; j < rects.length; j++) {
                const [a, ra] = rects[i];
                const [b, rb] = rects[j];
                if (a.contains(b) || b.contains(a)) continue;
                const w = Math.min(ra.right, rb.right) - Math.max(ra.left, rb.left);
                const h = Math.min(ra.bottom, rb.bottom) - Math.max(ra.top, rb.top);
                if (w > 2 && h > 2) out.push(`buttons "${name(a)}" and "${name(b)}" overlap`);
            }
        for (const b of btns) {
            // centred, as a player scrolls to it (at the very edge a sticky table head sits over it)
            b.scrollIntoView({ block: 'center', inline: 'nearest' });
            const r = b.getBoundingClientRect();
            const x = r.left + r.width / 2;
            const y = r.top + r.height / 2;
            if (x < 0 || y < 0 || x >= window.innerWidth || y >= window.innerHeight) continue;
            const top = document.elementFromPoint(x, y);
            // a toast passes on its own (it is dismissed before each click): only a lasting cover counts
            if (top && top !== b && !b.contains(top) && !top.contains(b) && !top.closest('.cp-toasts'))
                out.push(`button "${name(b)}" is covered by <${top.tagName.toLowerCase()} class="${top.className}">`);
        }
        return out;
    }, scope);
    for (const b of bad) fail(where, b);
}

// Toasts pass on their own after a few seconds; close them so the next click reaches the screen.
async function dismissToasts(page) {
    await page.evaluate(() => document.querySelectorAll('.cp-toasts .cp-toast__close').forEach(b => b.click()));
    if (await page.locator('.cp-toasts .cp-toast').count()) await page.waitForTimeout(300);
}

// Escape, then the dialog's close button, 4 times; a dialog still open after that is a failure (and the page is
// loaded again so the sweep goes on).
async function closeDialogs(page, where) {
    for (let k = 0; k < 4; k++) {
        if (!(await page.locator('[role="dialog"].cp-dialog').count())) return;
        await page.keyboard.press('Escape');
        await page.waitForTimeout(150);
        if (!(await page.locator('[role="dialog"].cp-dialog').count())) return;
        const close = page.locator('[role="dialog"].cp-dialog').last().locator('.cp-dialog__header button').first();
        if (await close.count()) await close.click({ timeout: 1000 }).catch(() => undefined);
        await page.waitForTimeout(150);
    }
    if (!(await page.locator('[role="dialog"].cp-dialog').count())) return;
    fail(where, 'the dialog could not be closed (Escape and its close button)');
    await page.reload();
    await page.waitForTimeout(500);
}
