"""Offline checks for the WPT import boundary."""

import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "import_corpus", Path(__file__).with_name("import_corpus.py")
)
import_corpus = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(import_corpus)


class ImportCorpusTests(unittest.TestCase):
    def test_metadata_preserves_script_and_variant_order(self):
        metadata = import_corpus.parse_metadata(
            "// META: global=window,dedicatedworker,jsshell\n"
            "// META: script=/wasm/jsapi/wasm-module-builder.js\n"
            "// META: script=assertions.js\n"
            "// META: variant=?first\n// META: variant=?second\n"
            "// META: timeout=long\n"
        )
        self.assertEqual(metadata["globals"], ["window", "dedicatedworker", "jsshell"])
        self.assertEqual(metadata["variants"], ["?first", "?second"])
        self.assertEqual(metadata["timeout"], "long")
        self.assertEqual(metadata["scripts"][1], "assertions.js")

    def test_missing_global_does_not_imply_shell_compatibility(self):
        metadata = import_corpus.parse_metadata("")
        self.assertEqual(metadata["globals"], ["window", "dedicatedworker"])
        self.assertIsNotNone(import_corpus.exclusion_reason("wasm/jsapi/example.any.js", metadata))

    def test_dependency_resolution_and_root_escape(self):
        fixture = "wasm/jsapi/table/get-set.any.js"
        self.assertEqual(import_corpus.resolve_script(fixture, "assertions.js"), "wasm/jsapi/table/assertions.js")
        self.assertEqual(import_corpus.resolve_script(fixture, "/wasm/jsapi/assertions.js"), "wasm/jsapi/assertions.js")
        for invalid in ("../../../../escape.js", "https://example.test/code.js", "//example.test/code.js", "helper.js?unknown=1", "helper.js#x"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                import_corpus.resolve_script(fixture, invalid)

    def test_scope_is_explicit_and_stable_unsupported_apis_stay_in_scope(self):
        metadata = import_corpus.parse_metadata("// META: global=jsshell")
        self.assertIsNone(import_corpus.exclusion_reason("wasm/jsapi/memory/to-resizable-buffer.any.js", metadata))
        for excluded in (
            "gc/casts.tentative.any.js", "jspi/notraps.any.js", "js-string/basic.any.js",
            "esm-integration/exports.tentative.any.js", "function/call.tentative.any.js",
            "tag/type.tentative.any.js", "memory/to-resizable-buffer-shared.any.js",
            "idlharness.any.js",
        ):
            with self.subTest(excluded=excluded):
                self.assertIsNotNone(import_corpus.exclusion_reason("wasm/jsapi/" + excluded, metadata))

    def test_shipped_exception_and_tag_apis_are_included_despite_tentative_names(self):
        metadata = import_corpus.parse_metadata("// META: global=jsshell")
        for fixture in (
            "exception/basic.tentative.any.js", "exception/constructor.tentative.any.js",
            "exception/getArg.tentative.any.js",
            "exception/is.tentative.any.js", "exception/toString.tentative.any.js",
            "tag/constructor.tentative.any.js", "tag/toString.tentative.any.js",
        ):
            with self.subTest(fixture=fixture):
                self.assertIsNone(import_corpus.exclusion_reason("wasm/jsapi/" + fixture, metadata))

    def test_remaining_tentative_exclusions_name_the_actual_proposal(self):
        metadata = import_corpus.parse_metadata("// META: global=jsshell")
        for fixture in (
            "global/type.tentative.any.js", "memory/type.tentative.any.js",
            "table/type.tentative.any.js", "tag/type.tentative.any.js",
            "memory/constructor-types.tentative.any.js", "table/constructor-types.tentative.any.js",
        ):
            with self.subTest(fixture=fixture):
                self.assertIn("type reflection", import_corpus.exclusion_reason("wasm/jsapi/" + fixture, metadata))
        self.assertIn("source-phase imports", import_corpus.exclusion_reason("wasm/jsapi/module/moduleSource.tentative.any.js", metadata))
        self.assertIn("detached Promise", import_corpus.exclusion_reason("wasm/jsapi/exception/identity.tentative.any.js", metadata))
        with self.assertRaisesRegex(ValueError, "review"):
            import_corpus.exclusion_reason("wasm/jsapi/new.tentative.any.js", metadata)

    def test_included_missing_dependency_is_an_error(self):
        files = {"wasm/jsapi/a.any.js": b"// META: global=jsshell\n// META: script=missing.js\n"}
        with self.assertRaisesRegex(ValueError, "missing dependency"):
            import_corpus.build_manifest(files, "a" * 40)

    def test_manifest_hashes_original_bytes_and_resolves_dependencies(self):
        files = {
            "wasm/jsapi/a.any.js": b"// META: global=jsshell\n// META: script=helper.js\r\n",
            "wasm/jsapi/helper.js": b"const helper = 1;\r\n",
            "wasm/jsapi/idlharness.any.js": b"// META: script=/resources/idlharness.js\n",
        }
        manifest = import_corpus.build_manifest(files, "a" * 40)
        self.assertEqual(manifest["tests"][0]["scripts"], ["wasm/jsapi/helper.js"])
        self.assertEqual(manifest["tests"][0]["variants"], [""])
        self.assertEqual(manifest["files"]["wasm/jsapi/helper.js"]["sha256"], hashlib.sha256(files["wasm/jsapi/helper.js"]).hexdigest())
        self.assertEqual(manifest["upstream"]["revision"], "a" * 40)
        self.assertIsNotNone(manifest["tests"][1]["excluded_reason"])

    def test_local_verification_rejects_modified_and_missing_files(self):
        files = {"wasm/jsapi/a.any.js": b"// META: global=jsshell\n"}
        manifest = import_corpus.build_manifest(files, "a" * 40)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "wasm/jsapi/a.any.js"
            file.parent.mkdir(parents=True)
            file.write_bytes(files["wasm/jsapi/a.any.js"])
            import_corpus.verify_local(root, manifest)
            file.write_bytes(b"modified")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                import_corpus.verify_local(root, manifest)
            file.unlink()
            with self.assertRaisesRegex(ValueError, "missing file"):
                import_corpus.verify_local(root, manifest)

    def test_git_blob_integrity_rejects_unexpected_download(self):
        data = b"upstream bytes\n"
        digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        import_corpus.verify_blob("fixture.js", data, digest)
        with self.assertRaisesRegex(ValueError, "Git blob mismatch"):
            import_corpus.verify_blob("fixture.js", b"different", digest)

    def test_harness_compatibility_source_must_match_exactly_once(self):
        source = br"/^\(\)\s*=>\s*(?:{(.*)}\s*|(.*))$/"
        import_corpus.verify_harness_compatibility(b"before " + source + b" after")
        for unexpected in (b"upstream changed", source + source):
            with self.assertRaisesRegex(ValueError, "harness compatibility"):
                import_corpus.verify_harness_compatibility(unexpected)


if __name__ == "__main__":
    unittest.main()
