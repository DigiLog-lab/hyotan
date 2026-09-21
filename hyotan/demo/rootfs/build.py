#!/usr/bin/env python3
"""Build the guest rootfs archive that the demo app expands on first launch.

The same recipe (and the same archive) is used by the Struis iOS app, which is why a few
files inside the guest carry its name (`etc/struis-rootfs.json`, `etc/profile.d/struis.sh`).

    python3 hyotan/demo/rootfs/build.py            # writes rootfs-v<N>.tar.gz
    python3 hyotan/demo/rootfs/build.py --check    # verify inputs against rootfs.lock.json only

Inputs (all pinned by URL + SHA-256 in rootfs.lock.json):

1. Alpine 3.21 aarch64 minirootfs
2. Alpine 3.21 packages: python3 (+pyc), py3-numpy (+pyc), py3-sympy (+pyc),
   ripgrep, zsh, bash, ca-certificates-bundle, resolved recursively from the
   pinned APKINDEX snapshots. Package payloads are extracted; maintainer
   scripts are not executed (no Linux binary runs on the build Mac).
3. Codex CLI 0.153.4 (npm `@openai/codex@0.153.4-linux-arm64`): `bin/codex` and `bin/codex-code-mode-host`
   (static musl). The bundled glibc `rg` / `zsh` / `bwrap` are not usable in
   the guest and are replaced by the Alpine packages above.

The archive is a GNU tar: symlinks are tar symlinks, modes/uid/gid are kept,
mtimes are fixed so the output is reproducible byte-for-byte for the same
inputs. The app-side importer (`Runtime/RootfsInstaller.swift`) turns it into
an iSH fakefs (meta.db + data/).
"""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".cache"
LOCK_PATH = HERE / "rootfs.lock.json"
MANIFEST_PATH = HERE / "rootfs-manifest.plist"

ROOTFS_VERSION = 2
ALPINE_BRANCH = "v3.21"
ALPINE_MINIROOTFS = {
    "name": "alpine-minirootfs-3.21.7-aarch64.tar.gz",
    "url": "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.7-aarch64.tar.gz",
}
CODEX_VERSION = "0.153.4"
CODEX_PACKAGE = {
    "name": f"codex-linux-arm64-{CODEX_VERSION}.tgz",
    "url": f"https://registry.npmjs.org/@openai/codex/-/codex-{CODEX_VERSION}-linux-arm64.tgz",
}
WANTED_PACKAGES = [
    "python3",
    "python3-pyc",
    "py3-numpy",
    "py3-numpy-pyc",
    "py3-sympy",
    "py3-sympy-pyc",
    "ripgrep",
    "zsh",
    "bash",
    "ca-certificates-bundle",
]
FIXED_MTIME = 1_700_000_000  # reproducible archives


def sha256_of(path: Path) -> str:
    with path.open("rb") as source:
        # hashlib.file_digest is 3.11+; Xcode Cloud runs the system Python 3.9.
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
        return digest.hexdigest()


def fetch(asset: dict, *, expected: str | None) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / asset["name"]
    if not path.exists():
        print(f"downloading {asset['name']}", flush=True)
        tmp = path.with_suffix(path.suffix + ".part")
        # curl uses the system trust store; the Python that Xcode Cloud runs may not
        # have CA certificates configured for urllib. Integrity comes from the sha256 pin.
        curl = shutil.which("curl")
        if curl:
            subprocess.run(
                [curl, "--fail", "--silent", "--show-error", "--location", "--retry", "3",
                 "--connect-timeout", "30", "--output", str(tmp), asset["url"]],
                check=True,
            )
        else:
            with urllib.request.urlopen(asset["url"], timeout=120) as response, tmp.open("wb") as out:
                shutil.copyfileobj(response, out)
        tmp.replace(path)
    actual = sha256_of(path)
    if expected and actual != expected:
        raise SystemExit(f"sha256 mismatch for {asset['name']}: {actual} != {expected}")
    asset["sha256"] = actual
    asset["size"] = path.stat().st_size
    return path


# --------------------------------------------------------------------------
# APK resolution
# --------------------------------------------------------------------------


def dependency_name(value: str) -> str:
    return re.split(r"[<>=~]", value, 1)[0]


def parse_apkindex(path: Path) -> list[dict[str, str]]:
    with tarfile.open(path, ignore_zeros=True) as archive:
        member = archive.extractfile("APKINDEX")
        assert member is not None
        content = member.read().decode()
    records = []
    for block in content.split("\n\n"):
        record = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
        if "P" in record:
            records.append(record)
    return records


def installed_in_minirootfs(minirootfs: Path) -> set[str]:
    with tarfile.open(minirootfs) as archive:
        member = archive.extractfile("./lib/apk/db/installed")
        if member is None:
            member = archive.extractfile("lib/apk/db/installed")
        assert member is not None
        text = member.read().decode()
    return {line[2:] for line in text.splitlines() if line.startswith("P:")}


def resolve_packages(indexes: dict[str, list[dict[str, str]]], skip: set[str]) -> list[dict]:
    records: dict[str, dict[str, str]] = {}
    providers: dict[str, str] = {}
    for repository, items in indexes.items():
        for record in items:
            record = {**record, "repository": repository}
            records.setdefault(record["P"], record)
            for value in record.get("p", "").split():
                providers.setdefault(dependency_name(value), record["P"])
    selected: dict[str, dict[str, str]] = {}

    def add(requirement: str) -> None:
        if requirement.startswith("!"):
            return
        name = dependency_name(requirement)
        if name not in records:
            name = providers.get(name, name)
        if name in skip or name in selected:
            return
        if name not in records:
            raise SystemExit(f"cannot resolve Alpine package: {requirement}")
        record = records[name]
        selected[name] = record
        for dependency in record.get("D", "").split():
            add(dependency)

    for name in WANTED_PACKAGES:
        add(name)
    packages = []
    for name, record in sorted(selected.items()):
        filename = f"{name}-{record['V']}.apk"
        packages.append(
            {
                "name": filename,
                "package": name,
                "version": record["V"],
                "license": record.get("L", ""),
                "url": f"https://dl-cdn.alpinelinux.org/alpine/{ALPINE_BRANCH}/{record['repository']}/aarch64/{filename}",
                "apk_control_checksum": record["C"],
            }
        )
    return packages


def gzip_members(path: Path):
    import zlib

    remaining = path.read_bytes()
    while remaining:
        inflater = zlib.decompressobj(31)
        contents = inflater.decompress(remaining) + inflater.flush()
        if not inflater.eof:
            raise SystemExit(f"incomplete gzip stream: {path.name}")
        consumed = len(remaining) - len(inflater.unused_data)
        yield remaining[:consumed], contents
        remaining = inflater.unused_data


def verify_apk(path: Path, expected: str) -> None:
    """APKINDEX `C:` is `Q1` + base64(sha1(control segment))."""
    if not expected.startswith("Q1"):
        raise SystemExit(f"unsupported apk checksum {expected}")
    for compressed, contents in gzip_members(path):
        with tarfile.open(fileobj=io.BytesIO(contents), ignore_zeros=True) as archive:
            if ".PKGINFO" in archive.getnames():
                actual = "Q1" + base64.b64encode(hashlib.sha1(compressed).digest()).decode()
                if actual != expected:
                    raise SystemExit(f"apk control checksum mismatch: {path.name}: {actual}")
                return
    raise SystemExit(f"apk control segment missing: {path.name}")


# --------------------------------------------------------------------------
# Staging tree
# --------------------------------------------------------------------------


class Tree:
    """A staging directory. Symlinks stay symlinks; modes are recorded in the
    host filesystem where possible and in a side table otherwise."""

    def __init__(self, root: Path):
        self.root = root
        self.meta: dict[str, tuple[int, int, int]] = {}  # rel -> (mode, uid, gid)

    @staticmethod
    def normalized(name: str) -> str:
        parts = [p for p in PurePosixPath(name).parts if p not in ("/", ".")]
        if ".." in parts:
            raise SystemExit(f"path traversal in archive: {name}")
        return "/".join(parts)

    def _host(self, rel: str) -> Path:
        return self.root / rel if rel else self.root

    def directory(self, rel: str, mode: int = 0o755, uid: int = 0, gid: int = 0) -> None:
        rel = self.normalized(rel)
        path = self._host(rel)
        if path.is_symlink():
            return
        path.mkdir(parents=True, exist_ok=True)
        self.meta[rel] = (stat.S_IFDIR | (mode & 0o7777), uid, gid)

    def ensure_parents(self, rel: str) -> None:
        parent = PurePosixPath(rel).parent
        if str(parent) not in (".", ""):
            chain = []
            while str(parent) not in (".", ""):
                chain.append(str(parent))
                parent = parent.parent
            for item in reversed(chain):
                if item not in self.meta and not self._host(item).exists():
                    self.directory(item)

    def file(self, rel: str, stream, mode: int = 0o644, uid: int = 0, gid: int = 0) -> None:
        rel = self.normalized(rel)
        self.ensure_parents(rel)
        path = self._host(rel)
        if path.is_dir() and not path.is_symlink():
            raise SystemExit(f"cannot replace directory with file: {rel}")
        if path.is_symlink() or path.exists():
            path.unlink()
        with path.open("wb") as out:
            if isinstance(stream, bytes):
                out.write(stream)
            else:
                shutil.copyfileobj(stream, out)
        os.chmod(path, 0o644)
        self.meta[rel] = (stat.S_IFREG | (mode & 0o7777), uid, gid)

    def symlink(self, rel: str, target: str, uid: int = 0, gid: int = 0) -> None:
        rel = self.normalized(rel)
        self.ensure_parents(rel)
        path = self._host(rel)
        if path.is_symlink() or path.exists():
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
        os.symlink(target, path)
        self.meta[rel] = (stat.S_IFLNK | 0o777, uid, gid)

    def remove(self, rel: str) -> None:
        rel = self.normalized(rel)
        path = self._host(rel)
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
        for key in [k for k in self.meta if k == rel or k.startswith(rel + "/")]:
            del self.meta[key]

    def import_tar(self, source: Path, *, skip_dotfiles: bool = False) -> None:
        hardlinks: list[tuple[str, str]] = []
        with tarfile.open(source, ignore_zeros=True) as archive:
            for member in archive:
                rel = self.normalized(member.name)
                if not rel:
                    continue
                if skip_dotfiles and PurePosixPath(rel).parts[0].startswith("."):
                    continue
                if member.isdir():
                    self.directory(rel, member.mode, member.uid, member.gid)
                elif member.issym():
                    self.symlink(rel, member.linkname, member.uid, member.gid)
                elif member.islnk():
                    hardlinks.append((rel, self.normalized(member.linkname)))
                elif member.isfile():
                    self.file(rel, archive.extractfile(member), member.mode, member.uid, member.gid)
                elif member.ischr() or member.isblk() or member.isfifo():
                    continue  # /dev nodes are created by the runtime at boot
                else:
                    raise SystemExit(f"unsupported tar member: {member.name}")
        for rel, target in hardlinks:
            src = self._host(target)
            if not src.exists():
                raise SystemExit(f"unresolved hardlink {rel} -> {target}")
            self.file(rel, src.read_bytes(), self.meta.get(target, (0o644, 0, 0))[0] & 0o7777)


CODEX_BINARIES = (
    # The CLI itself, and the tool host it spawns for every shell/exec tool call
    # ("tool host `/usr/local/bin/codex-code-mode-host` is missing" without it).
    "codex",
    "codex-code-mode-host",
)


def import_codex(tree: Tree, package: Path) -> None:
    with tarfile.open(package) as archive:
        for name in CODEX_BINARIES:
            member = archive.getmember(f"package/vendor/aarch64-unknown-linux-musl/bin/{name}")
            stream = archive.extractfile(member)
            assert stream is not None
            head = stream.read(20)
            if head[:6] != b"\x7fELF\x02\x01" or int.from_bytes(head[18:20], "little") != 183:
                raise SystemExit(f"{name} is not an ARM64 Linux ELF")
            tree.file(f"usr/local/bin/{name}", head + stream.read(), 0o755)


def prune(tree: Tree) -> None:
    """Drop what a tutor turn never runs: Python's test suites and docs."""
    python_root = tree.root / "usr/lib"
    for path in sorted(python_root.glob("python3.*/test")):
        tree.remove(str(path.relative_to(tree.root)))
    for path in sorted(python_root.glob("python3.*/site-packages/*/tests")):
        tree.remove(str(path.relative_to(tree.root)))
    for path in sorted(python_root.glob("python3.*/site-packages/numpy/**/tests")):
        if path.exists():
            tree.remove(str(path.relative_to(tree.root)))
    for rel in ("usr/share/doc", "usr/share/man", "usr/share/info"):
        if (tree.root / rel).exists():
            tree.remove(rel)


def write_archive(tree: Tree, output: Path) -> None:
    entries = sorted(tree.meta.items())
    with output.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as archive:
            for rel, (mode, uid, gid) in entries:
                info = tarfile.TarInfo(name=rel)
                info.mode = mode & 0o7777
                info.uid = uid
                info.gid = gid
                info.uname = ""
                info.gname = ""
                info.mtime = FIXED_MTIME
                host = tree.root / rel
                if stat.S_ISDIR(mode):
                    info.type = tarfile.DIRTYPE
                    archive.addfile(info)
                elif stat.S_ISLNK(mode):
                    info.type = tarfile.SYMTYPE
                    info.linkname = os.readlink(host)
                    archive.addfile(info)
                else:
                    info.type = tarfile.REGTYPE
                    info.size = host.stat().st_size
                    with host.open("rb") as source:
                        archive.addfile(info, source)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="only verify inputs against the lock file")
    parser.add_argument("--output", type=Path, default=HERE / f"rootfs-v{ROOTFS_VERSION}.tar.gz")
    args = parser.parse_args()

    previous = json.loads(LOCK_PATH.read_text()) if LOCK_PATH.exists() else {}
    locked_assets = {item["name"]: item for item in previous.get("assets", [])}
    locked_packages = previous.get("packages", [])

    minirootfs = dict(ALPINE_MINIROOTFS)
    codex = dict(CODEX_PACKAGE)
    minirootfs_path = fetch(minirootfs, expected=locked_assets.get(minirootfs["name"], {}).get("sha256"))
    codex_path = fetch(codex, expected=locked_assets.get(codex["name"], {}).get("sha256"))

    indexes_meta = []
    packages: list[dict]
    if locked_packages:
        packages = [dict(item) for item in locked_packages]
        indexes_meta = previous.get("indexes", [])
    else:
        parsed: dict[str, list[dict[str, str]]] = {}
        for repository in ("main", "community"):
            index = {
                "name": f"alpine-{ALPINE_BRANCH}-{repository}-APKINDEX.tar.gz",
                "url": f"https://dl-cdn.alpinelinux.org/alpine/{ALPINE_BRANCH}/{repository}/aarch64/APKINDEX.tar.gz",
            }
            path = fetch(index, expected=None)
            parsed[repository] = parse_apkindex(path)
            indexes_meta.append(index)
        packages = resolve_packages(parsed, installed_in_minirootfs(minirootfs_path))
    for package in packages:
        path = fetch(package, expected=package.get("sha256"))
        verify_apk(path, package["apk_control_checksum"])

    lock = {
        "rootfs_version": ROOTFS_VERSION,
        "architecture": "aarch64",
        "alpine": "3.21.7",
        "codex": CODEX_VERSION,
        "assets": [minirootfs, codex],
        "indexes": indexes_meta,
        "packages": packages,
        "package_installation": "payload extraction only; maintainer scripts are not executed",
    }
    if args.check:
        print(json.dumps({"ok": True, "packages": len(packages)}))
        return 0

    with tempfile.TemporaryDirectory(prefix="rootfs-build-", dir=CACHE) as staging:
        tree = Tree(Path(staging) / "root")
        tree.root.mkdir()
        print("importing minirootfs", flush=True)
        tree.import_tar(minirootfs_path)
        for package in packages:
            print(f"importing {package['name']}", flush=True)
            tree.import_tar(CACHE / package["name"], skip_dotfiles=True)
        print("importing codex", flush=True)
        import_codex(tree, codex_path)
        prune(tree)
        for rel in ("workspace", "root/.codex", "tmp", "proc", "dev/pts", "root/bin"):
            tree.directory(rel, 0o1777 if rel == "tmp" else 0o700 if rel.startswith("root") else 0o755)
        tree.file("root/.codex/config.toml", b"", 0o600)
        tree.file(
            "etc/profile.d/struis.sh",
            b"export PATH=/usr/local/bin:/root/bin:/usr/bin:/bin:/usr/sbin:/sbin\nexport CODEX_HOME=/root/.codex\nexport SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt\n",
            0o644,
        )
        tree.file(
            "etc/struis-rootfs.json",
            json.dumps({"rootfs_version": ROOTFS_VERSION, "alpine": "3.21.7", "codex": CODEX_VERSION}).encode() + b"\n",
            0o644,
        )
        total = sum((tree.root / rel).stat().st_size for rel, (mode, _, _) in tree.meta.items() if stat.S_ISREG(mode))
        print(f"writing {args.output.name} ({len(tree.meta)} paths, {total / 1e6:.1f} MB uncompressed)", flush=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        write_archive(tree, args.output)

    lock["archive"] = {
        "name": args.output.name,
        "sha256": sha256_of(args.output),
        "size": args.output.stat().st_size,
        "paths": len(tree.meta),
        "uncompressed_bytes": total,
    }
    LOCK_PATH.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n")
    MANIFEST_PATH.write_text(
        "\n".join(
            [
                '<?xml version="1.0" encoding="UTF-8"?>',
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
                '<plist version="1.0">',
                "<dict>",
                "\t<key>version</key>",
                f"\t<integer>{ROOTFS_VERSION}</integer>",
                "\t<key>archive</key>",
                f"\t<string>{args.output.name}</string>",
                "\t<key>sha256</key>",
                f"\t<string>{lock['archive']['sha256']}</string>",
                "\t<key>codex</key>",
                f"\t<string>{CODEX_VERSION}</string>",
                "\t<key>alpine</key>",
                "\t<string>3.21.7</string>",
                "</dict>",
                "</plist>",
                "",
            ]
        )
    )
    print(json.dumps(lock["archive"], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
