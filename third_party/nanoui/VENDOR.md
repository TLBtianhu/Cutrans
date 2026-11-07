# Vendored NanoUI

- Official upstream: <https://github.com/justrach/nanoui>
- Imported fork: <https://github.com/TLBtianhu/nanoui>, branch `otto-091`
- Fixed source commit: `00e5813dc5f524ece9a8f4aa37878cb6be1d125e`
- Official release commit: `d1330a84fca9581cdcaff7fa71041b2cccf3066b`
- Declared version: `0.12.0`; minimum Zig: `0.17.0`
- Alignment date: `2026-11-06`
- Source archive: <https://codeload.github.com/TLBtianhu/nanoui/tar.gz/00e5813dc5f524ece9a8f4aa37878cb6be1d125e>
- Source archive SHA-256: `b147aefb0ef2804444a10612117cd17e782183383b9a9234bc800558016857eb`

This is Cutrans's independent physical source copy, not a submodule,
symlink, or checkout shared with OTTO. Builds never use `C:\src\nanoui`
or another application's checkout. No upstream `.git`, generated output,
compiler cache, or initialized application submodules were imported.

Cutrans passes `.webview2 = "none"` and its own target and optimization
settings. NanoUI's MIT license, `THIRD_PARTY_NOTICES.md`, and
`third_party/licenses/` remain part of distributed Shells.

## Two layers of provenance

The source base is a fork, not an unmodified official release. It inherits
the fork's font indexing, mapped font bytes and other platform work. Any
future update must review both **official upstream → fork** and
**fork → Cutrans**; replaying Cutrans's patch list onto an official release
alone does not preserve all inherited behavior.

The official `v0.12.0` tree was independently compared with the fixed
fork: 32 source/document files differ. `VENDOR.json` records that complete
file list, the official archive fingerprint, and all eight Cutrans patch
files. The inherited changes include font indexing/mapping, image
handling, frame tracing/timing and Windows surface work.

The previous source base was `8a502ad120730e6b8484cdae5404211cccb88ff2`
(`0.10.0`). Its archive SHA-256 is
`46e37831a75b5ee7b9bf795168cc327dcf98a578ff34d97574fa18e3bb3c1b32`.
The update used that exact base, the existing Cutrans copy, and the new
fixed fork as three separate inputs. Comparisons normalize CRLF/LF only;
unchanged source is taken from the new base. No OTTO application defaults
or uncommitted local checkout changes are imported.

## Upstream changes absorbed by this base

- [#71](https://github.com/justrach/nanoui/pull/71): native RGB glyph
  coverage in D3D11, including removal of the extra test print.
- [#72](https://github.com/justrach/nanoui/pull/72): small-text GDI Classic
  grid fitting and resize without activating the window.
- [#75](https://github.com/justrach/nanoui/pull/75): scaled glyphs use
  linear grayscale; 1:1 glyphs keep RGB coverage at different DPI scales.
- [#76](https://github.com/justrach/nanoui/pull/76): DirectWrite borrows
  font bytes with correct owner reference accounting; tests compare the
  borrowed/copied paths and twenty creation/teardown cycles.

All four PRs were merged when checked. These behaviors now come from the
fixed base instead of duplicate Cutrans patches. The unused local
`rendering_override` audit hook is retired in favor of the base's tests.
New window client-size, frame reentrancy, minimize and transparency fixes
also remain intact. Linux page support is inherited source, not a claim
that Cutrans has implemented or verified a Linux application.

## Remaining local patches

1. **D3D11 per-frame textures.** `src/ui/d3d11_texture.zig`,
   `src/ui/d3d11.zig`, `src/ui/shader.hlsl`,
   `src/windows/surface_gpu.zig`, and `src/ui/tests_d3d11.zig`.
   Upload premultiplied BGRA with valid row stride, multiple slots, UV,
   rounded clipping, opacity and dimension replacement. `Renderer.draw`
   accepts the frame texture list; the real Windows surface forwards it.
   The new scaled-glyph shader and tests are retained alongside kind 8
   texture sampling. This does not provide external GPU zero-copy or
   video decoding.
2. **CPU texture stride parity.** `src/ui/raster.zig` accepts the final
   row without trailing padding: `(height - 1) * stride + width * 4`.
   The dynamic texture tests compare this path with real D3D11 readback.
3. **Public offscreen renderer.** `src/ui/ui.zig` exports `ui.d3d11` on
   Windows, allowing Cutrans to verify its actual renderer independently
   from CPU snapshots.
4. **Opt-in persistent values.** `src/windows/app.zig` adds `Options.kv`
   (default `true`). Cutrans selects `false`, keeping KV in memory and
   preventing implicit reads from another application/data environment.

These **eight source files** are the complete deviations from the new
fork base. `VENDOR.md` and `VENDOR.json` are Cutrans's provenance records. Local patches
remain candidates for a coherent upstream batch; no new PR is implied.

## Update and verification policy

- Keep Cutrans desktop, resource-library, Host and VM semantics outside
  NanoUI. Application layout policy belongs to the application too.
- Review overlapping behavior, not just merge conflicts. Never replace
  the new base with an old copy of all locally modified files.
- Keep generally useful fixes with their focused tests and CPU/D3D
  comparisons; batch mature changes into a small number of upstream PRs.
- Source alignment alone is not acceptance. Before release, run Cutrans's
  `test-nanoui`, `test-nanoui-library`, `verify-nanoui-library` and
  `verify-nanoui-portable`, plus the standard runtime checks and the
  isolated installer gate when packaging changes. Run heavy builds
  sequentially. Record actual results in the project implementation log.
- Recheck the 600-line rule and cross-target build boundaries. GUI
  appearance, IME and real interaction require separate user acceptance;
  no synthetic desktop input or screen capture is used.
