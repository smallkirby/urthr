# Urthr

![Zig](https://shields.io/badge/Zig-v0%2E15%2E2-blue?logo=zig&color=F7A41D&style=for-the-badge)

## Development

### Raspberry Pi 4 emulated on QEMU

```bash
zig build run --summary all -Dlog_level=debug -Doptimize=Debug -Dboard=rpi4b
```

### Raspberry Pi 5

```bash
zig build run --summary all -Dlog_level=debug -Doptimize=Debug -Dboard=rpi5

# TODO: copy artifacts and copy them to an SD card
```

### Unit Tests

```bash
zig build test --summary all -Doptimize=Debug
```

## Options

| Option | Type | Description | Default |
|---|---|---|---|
| `board` | String: `rpi4b`, `rpi5` | Target board. | `rpi4b` |
| `log_level` | String: `debug`, `info`, `warn`, `error` | Logging level. Output under the logging level is suppressed. | `info` |
| `optimize` | String: `Debug`, `ReleaseFast`, `ReleaseSmall` | Optimization level. | `Debug` |
| `wait_qemu` | Flag | Make QEMU wait for being attached by GDB. | `false` |
| `qemu` | Path | Path to QEMU (aarch64) directory. | `$HOME/qemu-aarch64` |
