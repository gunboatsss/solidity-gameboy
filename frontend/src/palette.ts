// 2bpp shades 0 (white)..3 (black) -> RGBA.
export const PALETTES: Record<string, [number, number, number][]> = {
  green: [
    [155, 188, 15],
    [139, 172, 15],
    [48, 98, 48],
    [15, 56, 15],
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
