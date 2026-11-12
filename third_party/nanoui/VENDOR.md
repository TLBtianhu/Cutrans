# Vendored NanoUI

- Official upstream: <https://github.com/justrach/nanoui>
- Base: official `v0.14.0`
- Fixed source commit: `7b3227295d37982306eee7b87b3e1fbbb76b3970`
- Minimum Zig: `0.17.0`
- Alignment date: `2026-11-10`
- Source archive: <https://codeload.github.com/justrach/nanoui/tar.gz/7b3227295d37982306eee7b87b3e1fbbb76b3970>
- Source archive SHA-256: `8b8a2abba224dfda294e0c3b91144866137e48ecf60b5f11a5815cd0091c4765`

This is Cutrans's independent physical source copy, not a submodule,
symlink, or checkout shared with OTTO. Builds never use `C:\src\nanoui`
or another application's checkout. No upstream `.git`, generated output,
compiler cache, or initialized application submodules were imported.

Cutrans passes `.webview2 = "none"` and its own target and optimization
settings. NanoUI's MIT license, `THIRD_PARTY_NOTICES.md`, and
`third_party/licenses/` remain part of distributed Shells.

## Base choice

The previous base was the `TLBtianhu/nanoui` fork at `00e5813` (`0.12.0`).
That fork inherited font indexing/mapping and other platform work which the
official `v0.14.0` now contains through the merged upstream work. The
official base also includes the app-drawn title bar implementation in
`src/windows/chrome.zig`: `decorations = true` + `title_bar = .hidden`
reclaims the caption band with `WM_NCCALCSIZE`, keeps the native resize
grips, Snap Layouts, system menu, DWM shadow and rounded corners, and maps
the view's `window_drag`/`window_maximize` boxes back to `HTCAPTION`/
`HTMAXBUTTON`.

Cutrans therefore no longer carries a borderless `WS_POPUP` window as its
main desktop. The experimental `border_resize.zig` hit test was not brought
forward; it only existed to make `WS_POPUP` resizable and is superseded by
`chrome.zig`.

`absorbed_pull_requests` records known upstream PRs whose changes are in this
base. It is provenance, not a count of any one contributor's merged PRs;
the v0.14 release also contains other merged work and release changes.

## Remaining local patches

Six source files differ from official `v0.14.0`:

1. **Public offscreen renderer.** `src/ui/ui.zig` exports
   `ui.d3d11` on Windows so Cutrans can verify its actual renderer against
   the CPU snapshots. Upstream keeps the renderer module private.
2. **Maximize-button hit code.** `src/ui/widgets.zig` adds
   `ButtonOptions.window_maximize`, passed into the button's style. It lets
   Cutrans's drawn maximize button answer `HTMAXBUTTON`, so Windows 11's
   Snap Layouts flyout still works under `title_bar = .hidden`.
3. **Successful GPU-present callback.** `src/window_types.zig`,
   `src/windows/window.zig`, and `src/windows/surface_gpu.zig` add
   `Options.on_present`, called after a successful GPU swap-chain present
   (not for GDI). Cutrans uses it for VM frame receipts.
4. **Opt-in persistent values.** `src/windows/app.zig` adds `Options.kv`
   (default `true`). Cutrans passes `false`, keeping KV in memory and
   preventing implicit reads from another NanoUI app's data directory.

The former D3D11 per-frame texture upload patch is retired: `v0.14.0` has
the `ui.texture`/`d3d11_texture` path and its own GPU/CPU tests. The former
CPU stride patch is also retired; the upstream image/texture paths handle
the final row without trailing padding. The fork-only `trace`,
`frame_timing` and `fontindex_win` files were not carried forward unless a
current source reference or test proves they are still needed.

## Update and verification policy

- Keep Cutrans desktop, resource-library, Host and VM semantics outside
  NanoUI. Application layout policy belongs to the application too.
- Review official-to-Cutrans diffs, not just merge conflicts. Never replace
  the new base with an old copy of all locally modified files.
- Keep generally useful fixes with focused tests; batch mature changes into
  a small number of upstream PRs. Do not submit duplicate features already
  in the base (`chrome.zig` is one).
- Source alignment alone is not acceptance. Before release, run Cutrans's
  `test-nanoui`, `test-nanoui-library`, `verify-nanoui-library` and
  `verify-nanoui-portable`, plus the standard runtime checks and the
  isolated installer gate when packaging changes. Run heavy builds
  sequentially. Record actual results in the project implementation log.
- Recheck the 600-line rule and cross-target build boundaries. GUI
  appearance, IME, real drag/resize/Snap and installation require separate
  user acceptance; no synthetic desktop input or screen capture is used.
