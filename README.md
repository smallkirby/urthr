# Urthr

![Zig](https://shields.io/badge/Zig-v0%2E15%2E2-blue?logo=zig&color=F7A41D&style=for-the-badge)

![Lint](https://github.com/smallkirby/urthr/actions/workflows/lint.yml/badge.svg)
![Unit Tests](https://github.com/smallkirby/urthr/actions/workflows/unittest.yml/badge.svg)
![Runtime Test Rpi4b](https://github.com/smallkirby/urthr/actions/workflows/runtime-test.yml/badge.svg)
![Build Rpi5](https://github.com/smallkirby/urthr/actions/workflows/build.yml/badge.svg)

## Development

### Raspberry Pi 4 emulated on QEMU

```bash
zig build run --summary all \
  -Dlog_level=debug \
  -Doptimize=Debug \
  -Dboard=rpi4b \
  -Drtt
```

### Raspberry Pi 5

All-in-one kernel:

```bash
zig build install --summary all \
  -Dlog_level=debug \
  -Doptimize=Debug \
  -Dboard=rpi5 \
  -Drestart \
  -Drtt \
  -Dsdcard=<path-to-your-sdcard-device>
```

Serial booteloader + kernel:

```bash
zig build install --summary all \
  -Dlog_level=debug \
  -Doptimize=Debug \
  -Dboard=rpi5 \
  -Dserial_boot \
  -Drestart \
  -Drtt \
  -Dsdcard=<path-to-your-sdcard-device>
```

Send the kernel to boot over serial:

```bash
./zig-out/bin/srboot ./zig-out/bin/remote <path-to-your-serial-device>
```

### Unit Tests

```bash
zig build test --summary all -Doptimize=Debug
```

## Options

| Option | Type | Description | Default |
|---|---|---|---|
| `board` | String: `rpi4b`, `rpi5` | Target board. | `rpi4b` |
| `serial_boot` | Flag | Generate bootloader and kernel as a separate binary. | `false` |
| `sdcard` | Path | Path to mounted SD card device. | - |
| `sdin` | Path | Path to SD card image file to be used by QEMU. | - |
| `log_level` | String: `debug`, `info`, `warn`, `error` | Logging level. Output under the logging level is suppressed. | `info` |
| `optimize` | String: `Debug`, `ReleaseFast`, `ReleaseSmall` | Optimization level. | `Debug` |
| `rtt` | Flag | Enable runtime tests. | `false` |
| `wait_qemu` | Flag | Make QEMU wait for being attached by GDB. | `false` |
| `qemu` | Path | Path to QEMU (aarch64) directory. | `$HOME/qemu-aarch64/bin` |
| `qemu_log` | String (Comma-separated): `sd` | Enable specified QEMU verbose log outputs. Comma-separated list. | - |
| `restart` | Flag | Restart the CPU instead of halting on EOL. | `false` |
