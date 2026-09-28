#!/usr/bin/env python3
"""Import or verify Cynic's pinned, byte-identical WPT wasm/jsapi snapshot.

Only Python's standard library is required. Downloads are checked against the
Git blobs in the pinned tree before any local corpus file is changed. The
manifest records SHA-256 hashes and the complete *.any.js selection, including
exclusions. Run --verify offline; use --revision <full commit SHA> to update.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import sys
import urllib.parse
import urllib.request


REPOSITORY = "https://github.com/web-platform-tests/wpt"
PINNED_REVISION = "9ee707c850996c8d124809570c3ff855d67301b9"
CORPUS_ROOT = Path(__file__).resolve().parents[2] / "vendor/wpt"
META = re.compile(r"^\s*//\s*META:\s*([^=\s]+)=(.*?)\s*$", re.MULTILINE)
HARNESS_ARROW_PATTERN = br"/^\(\)\s*=>\s*(?:{(.*)}\s*|(.*))$/"


def checked_path(path):
    """Keep upstream names and manifest paths inside the owned corpus root."""
    if not isinstance(path, str) or not path or "\\" in path:
        raise ValueError(f"invalid corpus path: {path!r}")
    parsed = PurePosixPath(path)
    if parsed.is_absolute() or ".." in parsed.parts or str(parsed) != path:
        raise ValueError(f"invalid corpus path: {path!r}")
    return path


def parse_metadata(source):
    # WPT .any.js defaults to Window + dedicated worker, never to jsshell.
    metadata = {"scripts": [], "variants": [], "globals": ["window", "dedicatedworker"], "timeout": "normal"}
    for key, value in META.findall(source):
        if key == "script":
            metadata["scripts"].append(value)
        elif key == "variant":
            if value and not value.startswith(("?", "#")):
                raise ValueError(f"unsupported WPT variant: {value!r}")
            metadata["variants"].append(value)
        elif key == "global":
            metadata["globals"] = [item.strip() for item in value.split(",")]
        elif key == "timeout":
            if value not in ("normal", "long"):
                raise ValueError(f"unsupported WPT timeout: {value!r}")
            metadata["timeout"] = value
    if not metadata["variants"]:
        metadata["variants"] = [""]
    return metadata


def resolve_script(fixture, script):
    parsed = urllib.parse.urlsplit(script)
    if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment or "\\" in script or "%" in script:
        raise ValueError(f"unsupported META script URL in {fixture}: {script!r}")
    path = script[1:] if script.startswith("/") else posixpath.join(posixpath.dirname(fixture), script)
    return checked_path(posixpath.normpath(path))


def exclusion_reason(path, metadata):
    relative = path.removeprefix("wasm/jsapi/")
    categories = {
        "esm-integration/": "Wasm ES module integration and module-host loading are outside the initial shell scope",
        "function/": "WebAssembly.Function proposal API is outside the initial stable API scope",
        "gc/": "Wasm GC is outside the initial shipped-feature scope",
        "js-string/": "Wasm JS string builtins are outside the initial shipped-feature scope",
        "jspi/": "Wasm JS Promise Integration is outside the initial shipped-feature scope",
    }
    for prefix, reason in categories.items():
        if relative.startswith(prefix):
            return reason
    if relative == "idlharness.any.js":
        return "WebIDL harness requires browser fetch/IDL resources and does not declare jsshell"
    if "-shared." in relative or "/threads/" in path:
        return "Shared Wasm memory and threads are outside the initial shell scope"
    if relative == "exception/identity.tentative.any.js":
        return "Fixture uses detached Promise assertions inside synchronous test(); shell lacks host rejection tracking and could falsely pass"
    if relative in {
        "global/type.tentative.any.js", "memory/type.tentative.any.js",
        "table/type.tentative.any.js", "tag/type.tentative.any.js",
        "memory/constructor-types.tentative.any.js", "table/constructor-types.tentative.any.js",
    }:
        return "Wasm JS type reflection proposal (type methods/minimum descriptors) is outside the shipped API scope"
    if relative == "module/moduleSource.tentative.any.js":
        return "Wasm source-phase imports and AbstractModuleSource are outside the shipped API scope"
    shipped_tentative = {
        "exception/basic.tentative.any.js", "exception/constructor.tentative.any.js",
        "exception/getArg.tentative.any.js", "exception/is.tentative.any.js",
        "exception/toString.tentative.any.js", "tag/constructor.tentative.any.js",
        "tag/toString.tentative.any.js",
    }
    if ".tentative." in relative and relative not in shipped_tentative:
        raise ValueError(f"new tentative fixture needs explicit feature/shell review: {path}")
    if "jsshell" not in metadata["globals"]:
        return "Fixture does not explicitly declare the WPT jsshell environment"
    return None


def build_manifest(files, revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be a full lowercase 40-character Git commit SHA")
    entries = {}
    tests = []
    for path, data in sorted(files.items()):
        checked_path(path)
        entries[path] = {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
        if path.startswith("wasm/jsapi/") and path.endswith(".any.js"):
            metadata = parse_metadata(data.decode("utf-8"))
            excluded = exclusion_reason(path, metadata)
            scripts = [resolve_script(path, script) for script in metadata["scripts"]]
            tests.append({"path": path, "scripts": scripts, "variants": metadata["variants"],
                          "globals": metadata["globals"], "timeout": metadata["timeout"],
                          "excluded_reason": excluded})
            if excluded is None:
                pending = list(scripts)
                seen = set()
                while pending:
                    dependency = pending.pop()
                    if dependency in seen:
                        continue
                    seen.add(dependency)
                    if dependency not in files:
                        raise ValueError(f"missing dependency for {path}: {dependency}")
                    child = parse_metadata(files[dependency].decode("utf-8"))
                    pending.extend(resolve_script(dependency, script) for script in child["scripts"])
    return {"schema_version": 1, "upstream": {"repository": REPOSITORY, "revision": revision},
            "files": entries, "tests": tests}


def verify_blob(path, data, expected):
    actual = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
    if actual != expected:
        raise ValueError(f"Git blob mismatch for {path}: expected {expected}, got {actual}")


def verify_harness_compatibility(data):
    # The runner escapes these literal braces only in a temporary harness copy.
    # Changes to this upstream source need a deliberate compatibility review.
    count = data.count(HARNESS_ARROW_PATTERN)
    if count != 1:
        raise ValueError(f"unexpected harness compatibility source: expected one arrow regex, found {count}")


def verify_local(root, manifest):
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported WPT manifest schema")
    files = {}
    for path, entry in manifest["files"].items():
        local = root / checked_path(path)
        if not local.is_file():
            raise ValueError(f"missing file: {path}")
        if local.is_symlink() or not local.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"corpus file escapes root: {path}")
        data = local.read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["sha256"] or len(data) != entry["size"]:
            raise ValueError(f"hash mismatch: {path}")
        files[path] = data
    expected = build_manifest(files, manifest["upstream"]["revision"])
    if manifest != expected:
        raise ValueError("manifest metadata does not match the original source files")
    if "resources/testharness.js" in files:
        verify_harness_compatibility(files["resources/testharness.js"])


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Cynic-WPT-importer", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def github_tree(revision, recursive=False):
    suffix = "?recursive=1" if recursive else ""
    response = json.loads(download(f"https://api.github.com/repos/web-platform-tests/wpt/git/trees/{revision}{suffix}"))
    if response.get("truncated"):
        raise ValueError("GitHub returned a truncated tree; refusing an incomplete import")
    return {entry["path"]: entry for entry in response["tree"]}


def fetch_corpus(revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be a full lowercase 40-character Git commit SHA")
    root = github_tree(revision)
    wasm = github_tree(root["wasm"]["sha"])
    subtree = github_tree(wasm["jsapi"]["sha"], recursive=True)
    resources = github_tree(root["resources"]["sha"])
    blobs = {"wasm/jsapi/" + path: entry for path, entry in subtree.items() if entry["type"] == "blob"}
    blobs["LICENSE.md"] = root["LICENSE.md"]
    blobs["resources/testharness.js"] = resources["testharness.js"]
    for path, entry in blobs.items():
        checked_path(path)
        if entry["mode"] not in ("100644", "100755"):
            raise ValueError(f"unsupported upstream file mode: {path} ({entry['mode']})")

    def fetch(item):
        path, entry = item
        data = download(f"https://raw.githubusercontent.com/web-platform-tests/wpt/{revision}/{path}")
        verify_blob(path, data, entry["sha"])
        return path, data

    with ThreadPoolExecutor(max_workers=8) as executor:
        files = dict(executor.map(fetch, sorted(blobs.items())))
    verify_harness_compatibility(files["resources/testharness.js"])
    return files


def write_corpus(root, files, manifest):
    # Download/validation completes before the first mutation. Remove only stale
    # files named by the previous manifest; local notes are not deletion targets.
    old_manifest = root / "manifest.json"
    old_files = json.loads(old_manifest.read_text())["files"] if old_manifest.exists() else {}
    for path in old_files:
        checked_path(path)
    for path, data in files.items():
        destination = root / checked_path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.resolve().is_relative_to(root.resolve()) or destination.is_symlink():
            raise ValueError(f"corpus destination escapes root: {path}")
        destination.write_bytes(data)
    for path in old_files.keys() - files.keys():
        destination = root / path
        if destination.exists():
            destination.unlink()
    old_manifest.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="verify the committed snapshot offline")
    parser.add_argument("--revision", help="full upstream commit SHA to import")
    parser.add_argument("--destination", type=Path, default=CORPUS_ROOT)
    args = parser.parse_args(argv)
    manifest_path = args.destination / "manifest.json"
    if args.verify:
        if args.revision:
            parser.error("--verify and --revision cannot be combined")
        manifest = json.loads(manifest_path.read_text())
        verify_local(args.destination, manifest)
    else:
        revision = args.revision or (json.loads(manifest_path.read_text())["upstream"]["revision"] if manifest_path.exists() else PINNED_REVISION)
        files = fetch_corpus(revision)
        manifest = build_manifest(files, revision)
        write_corpus(args.destination, files, manifest)
        verify_local(args.destination, manifest)
    included = sum(test["excluded_reason"] is None for test in manifest["tests"])
    print(f"WPT {manifest['upstream']['revision']}: {len(manifest['files'])} verified files, "
          f"{included} in-scope fixtures, {len(manifest['tests']) - included} excluded fixtures")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"WPT import failed: {error}", file=sys.stderr)
        sys.exit(1)
