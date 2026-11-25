#!/usr/bin/env python3
"""Local isolated compile/run; no network, installs, existing servers or app launch."""
import pathlib
import platform
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="vape classification ") as scratch:
    temp = pathlib.Path(scratch)
    binary = temp / "classification-tests"
    command = ["xcrun", "swiftc", "-swift-version", "5", "-target", platform.machine() + "-apple-macosx13.0",
               "-module-cache-path", str(temp / "module-cache"), "-parse-as-library"]
    command += [str(p) for p in sorted((root / "native/Classification").glob("*.swift"))]
    command += [str(root / "native/Tests/ClassificationTests.swift"), "-o", str(binary)]
    subprocess.run(command, check=True)
    fixtures = temp / "synthetic fixtures"
    fixtures.mkdir()
    subprocess.run([str(binary), str(fixtures)], check=True)
