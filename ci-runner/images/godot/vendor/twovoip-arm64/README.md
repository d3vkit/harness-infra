# Vendored `twovoip` v4.2 — native `linux.arm64` libraries (VEN-1300)

Upstream `goatchurchprime/two-voip-godot-4` **v4.2** ships prebuilt libraries for
`linux.x86_64`, `macos`, `windows.x86_64`, `web`, `ios`, and `android.*` — but **not**
`linux.arm64`. Its `.gdextension` therefore has no `linux.arm64` entry.

The self-hosted CI runner for the **Ephemeral** Godot app is arm64 (Apple Silicon host). Without
a `linux.arm64` lib, Godot never registers the Opus classes (`AudioEffectOpusChunked` /
`AudioStreamOpusChunked`), so the whole Opus/voice test path (`test_opus_ext`, `test_opus_codec`,
`test_opus_decode`, `test_voice_pipeline`, `test_voice_receiver`, `test_voice_sender` — ~20 tests)
**PENDs green instead of running** — i.e. zero real CI coverage of the codec/wire-format.

These two `.so` files close that gap. They are built **from the v4.2 source tag** (upstream already
ships `android.arm64` from the same tree, so ARM support is proven), and
[`images/godot/Dockerfile`](../../Dockerfile) overlays them onto the baked upstream `twovoip` copy
on arm64 image builds (plus appends the matching `linux.arm64` / `linux.template_release.arm64`
entries to `twovoip.gdextension`). The version stamp stays `v4.2` — this *is* the v4.2 codebase,
just with an added arm64 build.

| File | `.gdextension` key | Loaded by |
|------|--------------------|-----------|
| `libtwovoip.linux.template_debug.arm64.so`   | `linux.arm64`                  | editor / `--headless` (what CI runs) |
| `libtwovoip.linux.template_release.arm64.so` | `linux.template_release.arm64` | exported release builds |

## Regenerating (on a version bump, or to rebuild from scratch)

Run [`build-arm64.sh`](build-arm64.sh) — it builds both templates in a **native** `linux/arm64`
container (no emulation on an arm64 host) and drops the two `.so` here:

```sh
cd ci-runner/images/godot/vendor/twovoip-arm64
./build-arm64.sh            # builds v4.2 by default; pass a tag to override: ./build-arm64.sh v4.2
```

Then rebuild + reset the runner image so it picks up the new libs (see `ci-runner/README.md`):

```sh
bin/ci-runner ephemeral reset 1   # ONLY while CI is idle — a reset mid-job zombies the runner
```

**Pin discipline:** the tag built here MUST match `ephemeral`'s `justfile` `twovoip_version` and the
`TWOVOIP_VERSION` ARG in the Dockerfile. Bumping twovoip means rebuilding these libs for the new tag
in the same change. Do NOT bump to v5.0 — it removed the chunked classes the voice pipeline uses.
