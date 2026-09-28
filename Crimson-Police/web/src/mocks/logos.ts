// Placeholder department logos for browser mode (inline SVG data URIs; no external URLs).
const svg = (s: string) => `data:image/svg+xml;charset=utf-8,${encodeURIComponent(s)}`;

export const SAST_LOGO = svg(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f7d25c"/><stop offset="1" stop-color="#c9971c"/></linearGradient></defs>
<path d="M256 24 448 96v150c0 118-82 198-192 242C146 444 64 364 64 246V96z" fill="#1f4e8c" stroke="url(#g)" stroke-width="18"/>
<path d="M256 70 408 126v120c0 94-64 158-152 196-88-38-152-102-152-196V126z" fill="none" stroke="#f2c230" stroke-width="5" opacity=".7"/>
<path d="m256 132 30 62 68 10-49 48 12 68-61-32-61 32 12-68-49-48 68-10z" fill="url(#g)"/>
<text x="256" y="398" text-anchor="middle" font-family="Arial, sans-serif" font-weight="700" font-size="58" fill="#f2c230" letter-spacing="6">SAST</text>
</svg>`);

export const FIB_LOGO = svg(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
<circle cx="256" cy="256" r="228" fill="#1c2541" stroke="#c9a227" stroke-width="16"/>
<circle cx="256" cy="256" r="186" fill="none" stroke="#c9a227" stroke-width="4" stroke-dasharray="4 10"/>
<path d="M256 118 356 160v74c0 66-42 112-100 136-58-24-100-70-100-136v-74z" fill="#c9a227"/>
<text x="256" y="274" text-anchor="middle" font-family="Georgia, serif" font-weight="700" font-size="74" fill="#1c2541">FIB</text>
</svg>`);

/** A URL that fails to load, to exercise the "no watermark, no broken image" path. */
export const BROKEN_LOGO = './logos/does-not-exist.png';
