# Urthr

## Development

### QEMU emulating Raspberry Pi 4

```bash
zig build run --summary all -Dboard=rpi4b -Dlog_level=debug -Doptimize=Debug
```

## Options

| Option | Type | Description | Default |
|---|---|---|---|
| `board` | String: `rpi4b`, `rpi5` | Target board. | `rpi4b` |
| `log_level` | String: `debug`, `info`, `warn`, `error` | Logging level. Output under the logging level is suppressed. | `info` |
| `optimize` | String: `Debug`, `ReleaseFast`, `ReleaseSmall` | Optimization level. | `Debug` |
| `wait_qemu` | Flag | Make QEMU wait for being attached by GDB. | `false` |
| `qemu` | Path | Path to QEMU (aarch64) directory. | `$HOME/qemu-aarch64` |
