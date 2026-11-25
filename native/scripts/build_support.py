"""Shared offline macOS build settings; no side effects on import."""
import platform
import hashlib
from pathlib import Path
import subprocess
import uuid

MINIMUM_MACOS = '13.0'


def compiler_flags(swift, sdk, cache, architecture=None, minimum=MINIMUM_MACOS):
    architecture = architecture or platform.machine()
    if architecture not in ('arm64', 'x86_64'):
        raise ValueError('Only arm64 and x86_64 are supported')
    return [swift, '-swift-version', '5', '-sdk', sdk, '-target',
            architecture + '-apple-macosx' + minimum, '-module-cache-path', str(cache), '-parse-as-library']


def module_cache(root, purpose='native'):
    # Clang module caches embed absolute paths. Moving a checkout needs a new cache.
    fingerprint = hashlib.sha256(str(Path(root).resolve()).encode()).hexdigest()[:16]
    return Path(root) / '.runtime' / (purpose + '-module-cache-' + fingerprint)


def discover_tools():
    if platform.system() != 'Darwin':
        raise RuntimeError('macOS and preinstalled Apple command-line tools are required')
    selected = subprocess.run(['/usr/bin/xcode-select', '-p'], capture_output=True, text=True)
    if selected.returncode or not Path(selected.stdout.strip()).is_dir():
        raise RuntimeError('Apple developer tools are not selected; no install or settings change attempted')
    swift = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    return swift, sdk


def canonical_root(root, swift, sdk):
    """Use Foundation's spelling without relaxing the native exact-path guard."""
    root = Path(root).resolve()
    runtime = root / '.runtime'
    runtime.mkdir(exist_ok=True)
    helper = runtime / ('path-check-' + uuid.uuid4().hex)
    helper.mkdir()
    source = helper / 'Path.swift'
    source.write_text('import Foundation\n@main enum P { static func main() { let u = URL(fileURLWithPath: CommandLine.arguments[1]); print(u.standardizedFileURL.resolvingSymlinksInPath().path) } }\n')
    executable = helper / 'PathCheck'
    subprocess.run(compiler_flags(swift, sdk, module_cache(root, 'path-helper')) + [str(source), '-o', str(executable)], check=True)
    value = subprocess.check_output([str(executable), str(root)], text=True).strip()
    if not value or not Path(value).samefile(root):
        raise RuntimeError('Foundation path does not identify this checkout')
    return Path(value), executable


def canonical_path(executable, path):
    value = subprocess.check_output([str(executable), str(path)], text=True).strip()
    if not value or not Path(value).samefile(path):
        raise RuntimeError('Foundation path does not identify the selected directory')
    return Path(value)
