"""Keep each resource's stream_enhanced/ in sync with its stream/.

FiveM Enhanced ignores stream/ when stream_enhanced/ exists, so stream_enhanced/
must hold an Alchemist-converted copy of every file in stream/.

A resource is a folder in the repository, or the repository root itself when the repository holds
one resource (stream/ and stream_enhanced/ at the top); messages call that root resource ".".

Commands:
    hook              Pre-commit: convert staged stream/ changes and stage the results.
    sync RESOURCE...  Build stream_enhanced/ for a resource from its working-tree
                      stream/ (use this to enable a resource for Enhanced).
                      Use "sync ." when the repository root is the resource.
    check             Report resources whose stream_enhanced/ doesn't match stream/.

When a commit changes stream/ in a resource that has no stream_enhanced/ yet, the hook creates it
from the resource's whole staged stream/. Resources are never given a stream_enhanced/ when they
contain a .enhanced-skip file or have a separate Enhanced resource next to them (NAME_enhanced),
e.g. sm_animations_assets and sm_traffic.
Resources with only stream_enhanced/ (no stream/) are Enhanced-only and are left alone.
Escrowed resources (with an .fxap file) are never converted: their files are encrypted.
Resources containing a .enhanced-manual file keep a hand-made stream_enhanced/ (e.g. one whose
file names differ from stream/) and are skipped too; the hook only reminds you when their stream/ changes.

Setup on each machine:
    git config core.hooksPath .githooks
    git config alchemist.cli "F:/FiveM/vAlchemist/AlchemistCli.exe"

Alchemist output isn't deterministic, so only changed files are ever converted.

Converted drawables (.ydr/.ydd/.yft) are also checked for models with more than 127 geometries:
Enhanced crashes when it streams one (GTA5_Enhanced+0x1b93d76, index -128), while Legacy and
Alchemist accept them. Split such a model into several models (CodeWalker XML, raise FlagsHigh).
"""

import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ENHANCED = "stream_enhanced"
MANUAL = ".enhanced-manual"
SKIP = ".enhanced-skip"
ESCROW = ".fxap"
ERROR_LINE = re.compile(r'^"(.+?)": error code (\d+), (.*)$')
DRAWABLE_EXTENSIONS = (".ydr", ".ydd", ".yft")
MAX_GEOMETRIES = 127


def git(*args, binary=False):
    # Literal pathspecs: folder names like [maps] would otherwise be glob patterns.
    result = subprocess.run(["git", "--literal-pathspecs", "-c", "core.quotepath=off", *args], capture_output=True, check=True)
    return result.stdout if binary else result.stdout.decode("utf-8")


def git_paths(*args, paths):
    """Run a git command on many paths without hitting the command-line length limit."""
    data = "\0".join(paths).encode("utf-8")
    subprocess.run(["git", "--literal-pathspecs", *args, "--pathspec-from-file=-", "--pathspec-file-nul"], input=data, capture_output=True, check=True)


def repo_root():
    return git("rev-parse", "--show-toplevel").strip()


def alchemist_path():
    path = os.environ.get("ALCHEMIST_CLI")
    if not path:
        try:
            path = git("config", "--get", "alchemist.cli").strip()
        except subprocess.CalledProcessError:
            path = ""
    if not path or not os.path.isfile(path):
        sys.exit(
            "enhanced_assets: Alchemist CLI not found. Set it with:\n"
            '    git config alchemist.cli "F:/FiveM/vAlchemist/AlchemistCli.exe"'
        )
    return path


def split_stream_path(path, folder="stream"):
    """'res/dir/stream/a/b.ydr' -> ('res/dir', 'a/b.ydr'), 'stream/a.ydr' -> ('.', 'a.ydr'); None if not under stream/."""
    marker = f"/{folder}/"
    index = ("/" + path).find(marker)
    if index < 0:
        return None
    return path[:index - 1] if index else ".", path[index - 1 + len(marker):]


def resource_page_size(flags):
    """Size of an RSC7 page set from its header flags (same as CodeWalker's GetSizeFromFlags)."""
    pages = (
        (((flags >> 27) & 0x1) << 0) + (((flags >> 26) & 0x1) << 1) + (((flags >> 25) & 0x1) << 2)
        + (((flags >> 24) & 0x1) << 3) + (((flags >> 17) & 0x7F) << 4) + (((flags >> 11) & 0x3F) << 5)
        + (((flags >> 7) & 0xF) << 6) + (((flags >> 5) & 0x3) << 7) + (((flags >> 4) & 0x1) << 8)
    )
    return (0x200 << (flags & 0xF)) * pages


def model_geometry_counts(data):
    """Geometry count of every model in a Legacy RSC7 drawable resource; [] if it can't be read (e.g. escrowed).

    Models are found by shape rather than by walking ydr/ydd/yft layouts: a pointer to the geometry
    array, the geometry count stored twice, pointers to bounds and shader mapping, and a geometry
    array of that many system pointers.
    """
    if len(data) < 16 or data[:4] != b"RSC7":
        return []
    system_flags = struct.unpack_from("<I", data, 8)[0]
    try:
        system = zlib.decompress(data[16:], -15)[:resource_page_size(system_flags)]
    except zlib.error:
        return []
    size = len(system)

    def system_pointer(value):
        return value >> 28 == 5 and value & 0x0FFFFFFF < size

    counts = []
    for offset in range(0, size - 0x30, 16):
        geometries, count, count_again = struct.unpack_from("<QHH", system, offset + 0x08)
        if count == 0 or count != count_again or not system_pointer(geometries):
            continue
        if not all(system_pointer(value) for value in struct.unpack_from("<QQ", system, offset + 0x18)):
            continue
        array = geometries & 0x0FFFFFFF
        if array + 8 * count > size or not all(system_pointer(value) for value in struct.unpack_from(f"<{count}Q", system, array)):
            continue
        counts.append(count)
    return counts


def geometry_warnings(inputs):
    warnings = []
    for relative, data in sorted(inputs.items()):
        if relative.lower().endswith(DRAWABLE_EXTENSIONS):
            too_many = [count for count in model_geometry_counts(data) if count > MAX_GEOMETRIES]
            if too_many:
                warnings.append(
                    f"{relative}: model with {max(too_many)} geometries; Enhanced crashes on more than "
                    f"{MAX_GEOMETRIES}, split it into several models"
                )
    return warnings


def run_alchemist(cli, source, target, relaxed=False):
    """Convert every file under source into target. Returns {relative path: error}."""
    args = [cli, "-f"] + (["--relaxed"] if relaxed else []) + [source, target]
    result = subprocess.run(args, capture_output=True, text=True, errors="replace")
    errors = {}
    for line in (result.stdout + result.stderr).splitlines():
        match = ERROR_LINE.match(line.strip())
        if match:
            failed = os.path.normpath(match.group(1).replace("\\\\", "\\"))
            relative = os.path.relpath(failed, source).replace("\\", "/")
            errors[relative] = f"{match.group(3)} (code {match.group(2)})"
    if result.returncode not in (0, 5) and not errors:
        sys.exit(f"enhanced_assets: Alchemist failed (exit {result.returncode}):\n{result.stdout}{result.stderr}")
    return errors


def convert(cli, inputs):
    """inputs: {relative path: bytes}. Returns ({relative path: bytes}, [warnings])."""
    warnings = geometry_warnings(inputs)
    with tempfile.TemporaryDirectory(prefix="enhanced-assets-") as work:
        source, target = os.path.join(work, "in"), os.path.join(work, "out")
        for relative, data in inputs.items():
            path = os.path.join(source, *relative.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as handle:
                handle.write(data)
        os.makedirs(target)

        failed = run_alchemist(cli, source, target)
        if failed:
            retry_source, retry_target = os.path.join(work, "retry-in"), os.path.join(work, "retry-out")
            for relative in failed:
                path = os.path.join(retry_source, *relative.split("/"))
                os.makedirs(os.path.dirname(path), exist_ok=True)
                shutil.copyfile(os.path.join(source, *relative.split("/")), path)
            os.makedirs(retry_target)
            still_failed = run_alchemist(cli, retry_source, retry_target, relaxed=True)
            for relative, error in failed.items():
                destination = os.path.join(target, *relative.split("/"))
                os.makedirs(os.path.dirname(destination), exist_ok=True)
                if relative in still_failed:
                    shutil.copyfile(os.path.join(source, *relative.split("/")), destination)
                    warnings.append(f"copied unconverted (failed even with --relaxed): {relative}: {still_failed[relative]}")
                else:
                    shutil.copyfile(os.path.join(retry_target, *relative.split("/")), destination)
                    warnings.append(f"converted with --relaxed: {relative}: {error}")

        outputs = {}
        for relative in inputs:
            path = os.path.join(target, *relative.split("/"))
            if not os.path.isfile(path):
                sys.exit(f"enhanced_assets: Alchemist produced no output for {relative}")
            with open(path, "rb") as handle:
                outputs[relative] = handle.read()
        return outputs, warnings


def write_file(root, path, data):
    full = os.path.join(root, *path.split("/"))
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as handle:
        handle.write(data)


def remove_file(root, path):
    full = os.path.join(root, *path.split("/"))
    if os.path.isfile(full):
        os.remove(full)
    directory = os.path.dirname(full)
    while os.path.isdir(directory) and not os.listdir(directory) and os.path.basename(directory) != ENHANCED:
        os.rmdir(directory)
        directory = os.path.dirname(directory)


def indexed_files(prefix):
    prefix = prefix.removeprefix("./")  # resource "." is the repository root
    return {
        path[len(prefix) + 1:]
        for path in git("ls-files", "-z", "--", prefix + "/").split("\0")
        if path
    }


def is_manual(resource):
    return os.path.isfile(os.path.join(*resource.split("/"), MANUAL))


def is_escrowed(resource):
    """Escrowed resources (with an .fxap) hold encrypted files that Alchemist can't convert."""
    return os.path.isfile(os.path.join(*resource.split("/"), ESCROW))


def is_legacy_only(resource):
    """True if the resource must never get a stream_enhanced/ of its own."""
    path = os.path.join(*resource.split("/"))
    return os.path.isfile(os.path.join(path, SKIP)) or os.path.isdir(path + "_enhanced")


def mismatch(resource):
    stream, enhanced = indexed_files(f"{resource}/stream"), indexed_files(f"{resource}/{ENHANCED}")
    if not stream or is_manual(resource):
        # Enhanced-only (e.g. sm_animations_assets_enhanced) or hand-made: nothing to mirror.
        return [], []
    return sorted(stream - enhanced), sorted(enhanced - stream)


def hook():
    root = repo_root()
    os.chdir(root)
    changes = git("diff", "--cached", "--name-status", "--no-renames", "-z").split("\0")
    to_convert, to_delete, touched, manual, created, escrowed = {}, [], set(), set(), set(), set()
    for status, path in zip(changes[0::2], changes[1::2]):
        enhanced = split_stream_path(path, ENHANCED)
        if enhanced:
            # Hand edits to stream_enhanced/ still have to leave it matching stream/.
            touched.add(enhanced[0])
            continue
        parts = split_stream_path(path)
        if not parts:
            continue
        resource, relative = parts
        if is_escrowed(resource):
            escrowed.add(resource)
            continue
        if is_manual(resource):
            manual.add(resource)
            continue
        if not os.path.isdir(os.path.join(root, *resource.split("/"), ENHANCED)):
            if not is_legacy_only(resource):
                created.add(resource)
            continue
        target = f"{resource}/{ENHANCED}/{relative}"
        if status == "D":
            to_delete.append(target)
        else:
            to_convert[target] = git("cat-file", "blob", f":{path}", binary=True)
        touched.add(resource)
    for resource in sorted(escrowed):
        print(f"enhanced_assets: note: {resource}/stream changed; it's escrowed ({ESCROW}), so it isn't converted for Enhanced")
    for resource in sorted(manual):
        print(f"enhanced_assets: note: {resource}/stream changed; its {ENHANCED}/ is hand-made ({MANUAL}), update it yourself")
    for resource in sorted(created):
        # New to Enhanced: convert the whole staged stream/, not just this commit's changes.
        staged = indexed_files(f"{resource}/stream")
        if not staged:
            continue
        print(f"enhanced_assets: creating {resource}/{ENHANCED} ({len(staged)} files)")
        for relative in staged:
            to_convert[f"{resource}/{ENHANCED}/{relative}"] = git("cat-file", "blob", f":{resource}/stream/{relative}", binary=True)
        touched.add(resource)
    if not touched:
        return

    resources = sorted(touched)
    if to_convert or to_delete:
        print(f"enhanced_assets: updating {ENHANCED}/ for {', '.join(resources)}")

    if to_convert:
        outputs, warnings = convert(alchemist_path(), to_convert)
        for path, data in outputs.items():
            write_file(root, path, data)
        for warning in warnings:
            print(f"enhanced_assets: warning: {warning}")
        git_paths("add", paths=outputs)
    for path in to_delete:
        remove_file(root, path)
    if to_delete:
        git_paths("rm", "--cached", "--quiet", "--ignore-unmatch", paths=to_delete)
    if to_convert or to_delete:
        print(f"enhanced_assets: converted {len(to_convert)}, removed {len(to_delete)}")

    problems = False
    for resource in resources:
        missing, extra = mismatch(resource)
        for path in missing:
            print(f"enhanced_assets: error: {resource}/{ENHANCED} is missing {path}")
        for path in extra:
            print(f"enhanced_assets: error: {resource}/{ENHANCED} has {path}, which isn't in stream/")
        problems = problems or bool(missing or extra)
    if problems:
        sys.exit(f"enhanced_assets: {ENHANCED}/ doesn't match stream/. Run: python .githooks/enhanced_assets.py sync <resource> (. for the repository root)")


def sync(resources):
    root = repo_root()
    cli = alchemist_path()
    for resource in resources:
        resource = os.path.relpath(os.path.abspath(resource), root).replace("\\", "/")
        stream = os.path.join(root, *resource.split("/"), "stream")
        if not os.path.isdir(stream):
            sys.exit(f"enhanced_assets: {resource} has no stream/ folder")
        if os.path.isfile(os.path.join(root, *resource.split("/"), MANUAL)):
            sys.exit(f"enhanced_assets: {resource} has a hand-made {ENHANCED}/ ({MANUAL}); not overwriting it")
        if os.path.isfile(os.path.join(root, *resource.split("/"), ESCROW)):
            sys.exit(f"enhanced_assets: {resource} is escrowed ({ESCROW}); its files can't be converted")
        inputs = {}
        for directory, _, files in os.walk(stream):
            for name in files:
                full = os.path.join(directory, name)
                with open(full, "rb") as handle:
                    inputs[os.path.relpath(full, stream).replace("\\", "/")] = handle.read()
        outputs, warnings = convert(cli, inputs)
        enhanced = os.path.join(root, *resource.split("/"), ENHANCED)
        if os.path.isdir(enhanced):
            shutil.rmtree(enhanced)
        for relative, data in outputs.items():
            write_file(root, f"{resource}/{ENHANCED}/{relative}", data)
        for warning in warnings:
            print(f"enhanced_assets: warning: {warning}")
        print(f"enhanced_assets: built {resource}/{ENHANCED} ({len(outputs)} files)")


def check():
    os.chdir(repo_root())
    resources = sorted({parts[0] for path in git("ls-files", "-z").split("\0") if (parts := split_stream_path(path, ENHANCED))})
    bad = 0
    for resource in resources:
        missing, extra = mismatch(resource)
        if missing or extra:
            bad += 1
            print(f"{resource}: missing {len(missing)}, extra {len(extra)}")
            for path in missing:
                print(f"    missing: {path}")
            for path in extra:
                print(f"    extra:   {path}")
    print(f"{len(resources) - bad} of {len(resources)} resources in sync")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "hook":
        hook()
    elif command == "sync" and len(sys.argv) > 2:
        sync(sys.argv[2:])
    elif command == "check":
        check()
    else:
        sys.exit(__doc__)
