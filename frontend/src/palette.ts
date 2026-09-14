// 2bpp shades 0 (white)..3 (black) -> RGBA.
export const PALETTES: Record<string, [number, number, number][]> = {
  gameboy: [
    [155, 188, 15],
    [139, 172, 15],
    [48, 98, 48],
    [15, 56, 15],
  ],
  monad: [
    [232, 228, 255],
    [176, 148, 255],
    [123, 63, 242],
    [43, 24, 95],
  ],
  ethereum: [
    [240, 242, 246],
    [188, 196, 208],
    [118, 128, 144],
    [44, 52, 66],
  ],
  robinhood: [
    [242, 255, 204],
    [204, 255, 0],
    [46, 110, 0],
    [12, 16, 6],
  ],
  base: [
    [204, 224, 255],
    [110, 155, 255],
    [0, 82, 255],
    [0, 26, 84],
  ],
  gray: [
    [255, 255, 255],
    [170, 170, 170],
    [85, 85, 85],
    [0, 0, 0],
  ],
};

export function drawFrame(
  ctx: CanvasRenderingContext2D,
  fb: Uint8Array,
  w: number,
  h: number,
  palette: [number, number, number][],
): void {
  const img = ctx.createImageData(w, h);
  const d = img.data;
  for (let i = 0; i < w * h; i++) {
    const [r, g, b] = palette[fb[i] & 3] ?? palette[0];
    d[i * 4] = r;
    d[i * 4 + 1] = g;
    d[i * 4 + 2] = b;
    d[i * 4 + 3] = 255;
  }
  ctx.putImageData(img, 0, 0);
}

export function serialToText(bytes: number[]): string {
  return bytes
    .map((b) => (b >= 32 && b < 127 ? String.fromCharCode(b) : b === 10 ? '\n' : '�'))
    .join('');
}

/** Apply a palette page-wide: shades drive the CSS theme
 *  (bg darkest, text lightest, accent second-lightest). Derived tones are
 *  mixed in JS (no color-mix dependency) so every browser follows. */
export function applyPageTheme(name: string): void {
  const pal = PALETTES[name] ?? PALETTES.gameboy;
  const css = (c: [number, number, number]): string => `rgb(${c[0]}, ${c[1]}, ${c[2]})`;
  const mix = (a: [number, number, number], b: [number, number, number], t: number): string =>
    css([
      Math.round(a[0] + (b[0] - a[0]) * t),
      Math.round(a[1] + (b[1] - a[1]) * t),
      Math.round(a[2] + (b[2] - a[2]) * t),
    ]);
  const [s0, s1, s2, s3] = pal as [
    [number, number, number],
    [number, number, number],
    [number, number, number],
    [number, number, number],
  ];
  const root = document.documentElement;
  root.style.setProperty('--sh0', css(s0));
  root.style.setProperty('--sh1', css(s1));
  root.style.setProperty('--sh2', css(s2));
  root.style.setProperty('--sh3', css(s3));
  root.style.setProperty('--bg', css(s3));
  root.style.setProperty('--card', mix(s3, s0, 0.12));
  root.style.setProperty('--line', css(s2));
  root.style.setProperty('--fg', css(s0));
  root.style.setProperty('--muted', mix(s0, s3, 0.38));
  root.style.setProperty('--accent', css(s1));
}
