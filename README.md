# powermon

A minimal power monitor for Linux laptops, written in Zig 0.16. One small static-ish binary records
power metrics into its own time series file and answers questions about them: statistics, terminal
charts, SVG, CSV.

## What it records

Every 5 seconds by default, one 48-byte record:

| metric | unit | source |
|---|---|---|
| `bat` | W | battery `power_now`; positive when discharging, negative when charging |
| `psys` | W | RAPL platform domain: SoC, memory and the rest of the platform |
| `pkg` | W | RAPL CPU package |
| `cores` | W | RAPL CPU cores |
| `gpu` | W | RAPL integrated GPU |
| `cpu` | % | CPU busy over the interval, from `/proc/stat` |
| `temp` | °C | CPU package temperature (hwmon `coretemp`) |
| `fan` | rpm | fan (hwmon `thinkpad`) |
| `pct` | % | battery charge |
| `wh` | Wh | battery energy remaining |
| `bright` | % | backlight |

plus the battery status, AC state, ACPI platform profile and a gap flag for the first sample after
start or resume. RAPL values are mean power over the interval, derived from the energy counters, so
integrated energy is exact whatever the sampling rate.

## No I/O on the sampling path

Every source is opened once at startup. A sample is then:

- one `read()` per RAPL counter on a `perf_event_open` descriptor (the `power` PMU), and
- a few `pread()`s on already-open sysfs and procfs attributes, which the kernel serves from memory.

No path lookups, no `open()`/`close()`, no allocation, no disk access. Samples are buffered in memory
and appended to the database in one `write()` every 60 samples (5 minutes), so the disk stays idle in
between. Queries send the recorder `SIGUSR1` first so they always include the latest samples.

The binary uses raw Linux syscalls throughout; libc is linked only for `localtime_r`.

## Database

`/var/lib/powermon/power.db`: a 64-byte header (magic `PWRMON\0\1`, record size, interval, creation
time) followed by fixed-size little-endian records in time order. Append-only; readers `mmap` the
file and binary-search on the timestamp. At 5 s it grows by about 0.8 MiB a day. The format is
trivial to read from other languages (see `src/db.zig`), and `powermon csv` exports everything.

## Usage

```
powermon now                      # one 1-second sample
powermon stats                    # last 24 h: min/p50/mean/p95/max, energy, drain per profile
powermon stats --since 7d
powermon plot bat psys --since 2h # terminal charts
powermon svg --since 24h > day.svg
powermon csv --since all > power.csv
powermon info
```

Durations: `90s 30m 6h 2d 1w` or `all`; `--until` takes the same form as "time ago".

## Install

```
contrib/install.sh
```

builds a release binary, installs `/usr/local/bin/powermon` and `powermon.service`, and starts it.
Debian sets `perf_event_paranoid=3` and its kernel patch then admits only `CAP_SYS_ADMIN` to
`perf_event_open` (`CAP_PERFMON` is not enough). So the service starts as root, opens the four RAPL
counters and the database, then `--user dann` switches uid/gid/groups for good, which clears every
capability; the recorder verifies that and refuses to run otherwise. It sees a read-only file system
except its state and runtime directories, and has no network.

## License

MIT. See [LICENSE](LICENSE).
