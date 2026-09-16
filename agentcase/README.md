# agentcase

Run coding agents on iOS. agentcase is an ARM64 Linux user-space runtime for
iOS apps, derived from [iSH](https://github.com/ish-app/ish) via
[OpenMinis/ish-arm64](https://github.com/OpenMinis/ish-arm64). An app links
the static libraries, mounts a rootfs, and starts Linux programs (an agent
such as Codex, plus Python, ripgrep, Typst, …) inside its own process. No
code is generated at run time; the interpreter is compiled ahead of time.

The current diff against upstream is mostly compatibility work needed to run
musl/Rust/Python agents: ARM64 instruction fixes, prctl/pdeathsig, large
lazy mappings for V8, cooperative process exit, and the removal of idle
"safety valves" that terminated long-running servers. See `git log
upstream/feature-arm64..` for the individual changes.

## Layout

Everything agentcase adds lives in this directory. The rest of the tree is
upstream iSH with a small, rebased set of fixes.

| Path | Purpose |
|---|---|
| `include/agentcase.h` | Public Objective-C API. The only header an app includes. |
| `bridge/AgentCaseRuntime.m` | Bridge between the API and the kernel. The only file that includes internal headers. |
| `scripts/build-runtime.sh` | Cross-builds the static libraries and the guest VDSO for one iOS SDK. |
| `checks/*.c` | Small Linux programs that verify instruction compatibility on the device. |
| `meson.build` | Adds `libagentcase.a` to the iSH Meson build (`-Dagentcase=true`). |

## Build

Requires Xcode with the iOS SDK and Python 3.11+. The script creates a venv
with Meson, Ninja and Zig under the build directory.

```sh
agentcase/scripts/build-runtime.sh iphonesimulator
agentcase/scripts/build-runtime.sh iphoneos
```

Artifacts land in `.build/<sdk>/`: `libish.a`, `libish_emu.a`, `libfakefs.a`,
`libagentcase.a`, `vdso/arm64/libvdso.so.elf` and the check programs. Set
`AGENTCASE_BUILD_DIR` to build elsewhere.

## Use from an app

Add `agentcase/include` to the header search path, link the four libraries
plus `-lsqlite3 -lresolv`, and:

```objc
AgentCaseRuntime *runtime = [[AgentCaseRuntime alloc] init];
runtime.environment = @[@"HOME=/root", @"PATH=/usr/local/bin:/usr/bin:/bin"];
[runtime bootRoot:rootfsPath workspace:workspacePath completion:^(NSString *error) {
    AgentCaseProcess *p = [runtime run:@"/bin/sh" arguments:@[@"-c", @"uname -m"]
        started:^(int pid) {} output:^(NSString *line, BOOL stderr) {} exited:^(int code) {}];
}];
```

`+[AgentCaseRuntime version]` returns the `git describe` string of the build,
so an app can show exactly which runtime commit it ships.

## Tracking upstream

```sh
git fetch upstream
git rebase upstream/feature-arm64
```

Conflicts can only occur in the files touched by our commits. Fixes that are
not iOS-specific are submitted upstream so the diff shrinks over time.

## License

agentcase is licensed under the GPLv3 (see `LICENSE.md`) with the additional
terms in `LICENSE.IOS`, the same as iSH. An app that links agentcase is a
combined work under the GPL; distribute its corresponding source under the
same terms. The upstream repositories are linked above.
