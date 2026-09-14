# test ROMs (not committed — download before running Blargg tests)

Base: https://raw.githubusercontent.com/retrio/gb-test-roms/master/cpu_instrs

- `cpu_instrs.gb` (combined suite)
- `individual/01-special.gb`
- `individual/02-interrupts.gb`
- `individual/03-op sp,hl.gb` -> save as `03.gb`
- `individual/04-op r,imm.gb` -> save as `04.gb`
- `individual/05-op rp.gb` -> save as `05.gb`
- `individual/06-ld r,r.gb` -> save as `06.gb`
- `individual/07-jr,jp,call,ret,rst.gb` -> save as `07.gb`
- `individual/08-misc instrs.gb` -> save as `08.gb`
- `individual/09-op r,r.gb` -> save as `09.gb`
- `individual/10-bit ops.gb` -> save as `10.gb`
- `individual/11-op a,(hl).gb` -> save as `11.gb`

URL-encode spaces as `%20`, e.g.:

```
base=https://raw.githubusercontent.com/retrio/gb-test-roms/master/cpu_instrs/individual
curl -o 03.gb "$base/03-op%20sp,hl.gb"
```
