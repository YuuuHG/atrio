# Fixed CasaOS core

CasaOS v0.4.15 stops several times a day with `fatal error: found pointer to free object` or
`fatal error: found bad pointer in Go heap`, and systemd starts it again
([IceWhaleTech/CasaOS#2581](https://github.com/IceWhaleTech/CasaOS/issues/2581)). Every 5 seconds CasaOS reads the
network counters, and three places copy them like this:

```go
item := *(*model.IOCountersStat)(unsafe.Pointer(&n))
```

`n` is gopsutil's `net.IOCountersStat`, 96 bytes on 64-bit systems; `model.IOCountersStat` has the same fields plus
`State` and `Time`, 120 bytes. The copy reads 24 bytes past the end of `n`, `State` gets whatever was there as its
string pointer, and when the garbage collector runs before that field is overwritten it finds the bad pointer and
stops the program. The fix ([IceWhaleTech/CasaOS#2582](https://github.com/IceWhaleTech/CasaOS/pull/2582), not merged
upstream) copies the fields one by one.

Atrio builds CasaOS v0.4.15 with that fix and, on servers that run IceWhale's own v0.4.15 binary, puts it in place
of `/usr/bin/casaos` (`scripts/atrio-core`). It can be turned off in Settings → Updates, and removing Atrio puts the
original back.

## What is here

- `fix-network-counters.patch`: the change, against CasaOS v0.4.15 (commit `ba285cb`). It adds
  `model.IOCountersStatFrom`, uses it in `route/periodical.go` and `route/v1/system.go`, and adds a test that fails
  if a field of either struct is not copied. Each changed file says so at the top.
- `build.sh`: builds `casaos-linux-amd64`, `casaos-linux-arm64` and `casaos-linux-arm-7` into
  `build/casaos-core/out`, with a `SHA256SUMS` file. `scripts/release.sh` runs it and uploads the three files with
  each release.

## Building it yourself

Everything that goes in is pinned: CasaOS's commit, the message bus API that its code generator reads, the code
generator, Go 1.23.4 (the version IceWhale built v0.4.15 with) and, through `go.sum`, every module. The same inputs
give the same files, byte for byte, so you can check a release's cores against your own build:

```shell
casaos-core/build.sh --force
cat build/casaos-core/out/SHA256SUMS
```

and compare with the `amd64=`, `arm64=` and `arm-7=` lines of `casaos-core` inside that release's
`atrio-server.tar.gz`.

The cores are built like IceWhale's `.goreleaser.yaml` builds CasaOS, with two differences: they are not packed
with upx, and they do not have IceWhale's keys for Google Drive, OneDrive and Dropbox, which are not public. Drives
already connected keep working, since their keys are saved with them; connecting a new one needs the original
core, so Atrio says to turn the fix off for that and on again after.

## License

CasaOS is Copyright IceWhale Technology and licensed under the Apache License 2.0, like Atrio. The cores Atrio
publishes are CasaOS v0.4.15 with the changes in `fix-network-counters.patch`, and keep that license.
