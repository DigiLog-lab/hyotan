# Hyotan demo

An iOS app that boots Hyotan and runs the Codex coding agent inside it. The agent's
commands, the files it writes and the guest's process tree (`ps` inside the guest) are shown
as they happen. Inference is the only part that leaves the device; everything Codex runs
(`sh`, `python3`, `apply_patch`, …) runs in the guest, inside the app's own process.

The app links the runtime built from this same tree. Every Xcode build first runs
`../scripts/build-runtime.sh` for the active SDK (incremental, a few seconds) and links
`../../.build/<sdk>/lib*.a`; the header comes from `../include`. Nothing prebuilt is checked in,
so a change to the runtime is in the demo on the next build. The System screen shows the
runtime's `git describe`.

## Build

Requires Xcode 26.5+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Python 3.11+ and an
iOS 26.4+ target.

```sh
git submodule update --init --depth 1 deps/libarchive deps/libapps
hyotan/demo/rootfs/build.sh            # rootfs-v2.tar.gz, ~160 MB, not checked in
cd hyotan/demo && xcodegen generate && open HyotanDemo.xcodeproj
```

Sign in with your own ChatGPT account from the app (device-code login). The credentials stay
in the guest's `/root/.codex`.

## Layout

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen spec, including the pre-build step that builds the runtime. |
| `rootfs/` | Recipe and manifest for the Alpine rootfs with Codex, Python and friends. |
| `HyotanDemo/Runtime/` | Boot, rootfs install, and the JSON-RPC session with `codex app-server`. |
| `HyotanDemo/Model/Machine.swift` | App state: boot → sign in → turns, transcript, `ps` polling. |
| `HyotanDemo/Views/` | SwiftUI screens (Liquid Glass). |

Simulator-only debug aids, compiled out of device builds: `HYOTAN_DEBUG_CODEX_AUTH_FILE=<auth.json>`
seeds a Codex login, `HYOTAN_DEBUG_PROMPT=<text>` sends one prompt on launch.
