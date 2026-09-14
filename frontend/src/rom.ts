// Pure Game Boy ROM-header parsing (cartridge metadata at fixed offsets).
// No imports: safe to use anywhere, including plain node check scripts.
export interface RomMeta {
  title: string;
  cgb: boolean;
  sgb: boolean;
  cartType: number;
  mapper: string;
  romSize: string;
  ramSize: string;
  version: number;
}

const CART_TYPES: Record<number, string> = {
  0x00: 'ROM only',
  0x01: 'MBC1',
  0x02: 'MBC1+RAM',
  0x03: 'MBC1+RAM+BATTERY',
  0x05: 'MBC2',
  0x06: 'MBC2+BATTERY',
  0x08: 'ROM+RAM',
  0x09: 'ROM+RAM+BATTERY',
  0x0b: 'MMM01',
  0x0c: 'MMM01+RAM',
  0x0d: 'MMM01+RAM+BATTERY',
  0x0f: 'MBC3+TIMER+BATTERY',
  0x10: 'MBC3+TIMER+RAM+BATTERY',
  0x11: 'MBC3',
  0x12: 'MBC3+RAM',
  0x13: 'MBC3+RAM+BATTERY',
  0x19: 'MBC5',
  0x1a: 'MBC5+RAM',
  0x1b: 'MBC5+RAM+BATTERY',
  0x1c: 'MBC5+RUMBLE',
  0x1d: 'MBC5+RUMBLE+RAM',
  0x1e: 'MBC5+RUMBLE+RAM+BATTERY',
};

function romSizeLabel(code: number): string {
  if (code < 0 || code > 8) return 'unknown';
  const kb = 32 << code;
  return kb >= 1024 ? `${kb / 1024}MB` : `${kb}KB`;
}

function ramSizeLabel(code: number): string {
  switch (code) {
    case 0:
      return 'no RAM';
    case 1:
      return '2KB';
    case 2:
      return '8KB';
    case 3:
      return '32KB';
    case 4:
      return '128KB';
    case 5:
      return '64KB';
    default:
      return 'unknown';
  }
}

export function parseRomMeta(rom: Uint8Array): RomMeta {
  const b = (i: number): number => rom[i] ?? 0;
  const cgb = (b(0x143) & 0x80) !== 0;
  const titleEnd = cgb ? 0x13f : 0x144;
  let title = '';
  for (let i = 0x134; i < titleEnd; i++) {
    const c = b(i);
    if (c === 0) break;
    title += c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '?';
  }
  const cartType = b(0x147);
  return {
    title,
    cgb,
    sgb: b(0x146) === 0x03,
    cartType,
    mapper: CART_TYPES[cartType] ?? 'unknown',
    romSize: romSizeLabel(b(0x148)),
    ramSize: ramSizeLabel(b(0x149)),
    version: b(0x14c),
  };
}
