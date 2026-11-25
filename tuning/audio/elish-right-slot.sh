#!/bin/bash
# postmarketOS elish wiki, "Stereo Speakers":
# CS35L41_SP_FRAME_RX_SLOT (0x00004820) defaults to 0x00000100.
# Only the least significant byte matters: 0x00 is the left channel
# and 0x02 is the right channel. In landscape with the USB port on
# the right, the whole i2c-1 bus (1-0040 .. 1-0043) is the right side.
# i2c-3 stays on the left channel (0x00000100).
# Without CONFIG_REGMAP_ALLOW_WRITE_DEBUGFS, the same registers are
# written over I2C. Runtime resume copies the cached default back, so
# keep rewriting them.
#
# The machine driver calls the DAI sysclk hook, which only programs the
# frequency monitor. PLL_CLK_CTRL stays at its reset value 0x10: SCLK
# selected, but REFCLK_FREQ 0 (32768 Hz). The Tertiary TDM bitclock is
# 12.288 MHz (48 kHz, 8 slots, 32-bit). Until REFCLK_FREQ is 0x33 the
# PLL stays unlocked and PUP_DONE never sets, so speakers are silent.
# Re-apply that sequence only when the register is not already
# 0x00000670, so a locked PLL is left alone.
set -u

write_slots() {
  local addr
  for addr in 0x40 0x41 0x42 0x43; do
    i2ctransfer -f -y 1 w8@"$addr" 0x00 0x00 0x48 0x20 0x00 0x00 0x00 0x02 >/dev/null
    i2ctransfer -f -y 3 w8@"$addr" 0x00 0x00 0x48 0x20 0x00 0x00 0x01 0x00 >/dev/null
  done
}

ensure_pll() {
  local cur
  cur=$(i2ctransfer -f -y 1 w4@0x40 0x00 0x00 0x2c 0x04 r4 2>/dev/null || true)
  if [ "$cur" = "0x00 0x00 0x06 0x70" ]; then
    return
  fi
  python3 - << 'PY'
import subprocess
amps = [("1","0x40"),("1","0x41"),("1","0x42"),("1","0x43"),
        ("3","0x40"),("3","0x41"),("3","0x42"),("3","0x43")]
PLL, OPENLOOP, REF_MASK, REF_SHIFT = 0x2C04, 1 << 11, 0x7E0, 5
CLK_EN, SEL_MASK, REF = 1 << 4, 0x7, 0x33
def xfer(bus, addr, reg, val=None):
    addr_b = [(reg >> 24) & 255, (reg >> 16) & 255, (reg >> 8) & 255, reg & 255]
    if val is None:
        cmd = ["i2ctransfer","-f","-y",bus,f"w4@{addr}"] + [f"0x{x:02x}" for x in addr_b] + ["r4"]
    else:
        vb = [(val >> 24) & 255, (val >> 16) & 255, (val >> 8) & 255, val & 255]
        cmd = ["i2ctransfer","-f","-y",bus,f"w8@{addr}"] + [f"0x{x:02x}" for x in addr_b + vb]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode:
        raise SystemExit(p.stderr.strip() or "i2c fail")
    if val is None:
        parts = p.stdout.split()
        return int("".join(x[2:] for x in parts), 16)
def rmw(bus, addr, mask, value):
    cur = xfer(bus, addr, PLL)
    nxt = (cur & ~mask) | (value & mask)
    if nxt != cur:
        xfer(bus, addr, PLL, nxt)
for bus, addr in amps:
    rmw(bus, addr, OPENLOOP, OPENLOOP)
    rmw(bus, addr, REF_MASK, REF << REF_SHIFT)
    rmw(bus, addr, CLK_EN, 0)
    rmw(bus, addr, SEL_MASK, 0)
    rmw(bus, addr, OPENLOOP, 0)
    rmw(bus, addr, CLK_EN, CLK_EN)
PY
}

while true; do
  write_slots
  ensure_pll
  sleep 0.4
done
