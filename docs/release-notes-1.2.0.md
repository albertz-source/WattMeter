# WattMeter 1.2.0

## New features

- **Hybrid supply (AC + battery)**: when a weak charger cannot cover the load, the flow diagram now
  shows two stacked sources on the left (adapter above, battery below) with two ribbons converging
  into the machine, a “Hybrid power” state, an adapter/battery split bar, and no charging branch on
  the right.
- **Battery-machine support**: `wattprobe --battery` dumps the full battery diagnostic (voltage and
  current, adapter, SMC rails, split, ports, temperatures, state and hints) so a MacBook can be
  verified in one command.
- `wattprobe --split-test`: 9 assertions covering adapter-only, charging, hybrid, battery-only,
  dead band, stale `PDTR` after unplugging, and missing input data.

## Fixes

- Battery current is decoded as signed even when a model stores `Amperage` as an unsigned 32-bit
  two's-complement value (battery power could previously be unreadable).
- Unplugging no longer leaves a stale `PDTR` that made the UI flash “hybrid” while on battery.
- In hybrid mode the net battery power is forced negative (discharging) instead of showing a
  positive value.
- The charging port is excluded from the `D1..D4` USB-C output rails by matching the adapter input
  power, so “Ports” no longer double-counts the charger.

## Notes

- Component temperatures, measured input V/A, bilingual UI and launch-at-login from 1.1.0 are
  unchanged.
- Still ad-hoc signed; macOS may ask you to confirm the first launch.
