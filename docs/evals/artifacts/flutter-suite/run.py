#!/usr/bin/env python3
"""Run the complete Flutter suite in two detached, prepared source trees."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time

OUT = Path(__file__).resolve().parent
LISTENER = """
package main
import (
    "net"
    "net/http"
    "testing"
)
func TestLocalFlutterSuiteListener(t *testing.T) {
    listener, err := net.Listen("tcp4", "127.0.0.1:9901")
    if err != nil { t.Fatal(err) }
    rooms := NewRoomStore(nil)
    t.Fatal(http.Serve(listener, setupMux(rooms, NewHub(rooms))))
}
"""
CLOCK = re.compile(r"^\d+:\d+(?::\d+)? \+(\d+)(?: ~(\d+))?(?: -(\d+))?:")


def execute(args, cwd, env):
    run = subprocess.run(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, errors="replace")
    return run.returncode, run.stdout


def suite(label, repo, sdk, cache, out):
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    lock = hashlib.sha256((repo / "pubspec.lock").read_bytes()).hexdigest()
    result = {"commit": revision, "pubspec_lock_sha256": lock}
    with tempfile.TemporaryDirectory(prefix="pilisync-suite-") as scratch:
        temp = Path(scratch)
        env = dict(os.environ, PUB_CACHE=str(cache), FLUTTER_ROOT=str(sdk),
                   FLUTTER_SUPPRESS_ANALYTICS="true", DART_SUPPRESS_ANALYTICS="true",
                   CI="true", LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8", GOWORK="off", GOPROXY="off", NO_PROXY="127.0.0.1,localhost",
                   no_proxy="127.0.0.1,localhost")
        # The mirror E2E launches "fvm dart ...". Delegate exactly that
        # command to the same pinned SDK as the test runner.
        fvm = temp / "fvm"
        fvm.write_text('#!/bin/sh\n[ "$1" = dart ] || exit 2\nshift\nexec "$FLUTTER_ROOT/bin/dart" "$@"\n')
        fvm.chmod(0o755)
        env["PATH"] = os.pathsep.join([str(temp), str(sdk / "bin"), env["PATH"]])

        def record(name, command, work=repo):
            code, output = execute(command, work, env)
            safe = "$ " + " ".join(command) + "\n" + output + f"\nexit={code}\n"
            for path, alias in [(repo, "<checkout>"), (sdk, "<sdk>"), (cache, "<pub-cache>"),
                                (temp, "<scratch>"), (Path(tempfile.gettempdir()), "<temp>"), (Path.home(), "<home>")]:
                safe = safe.replace(str(path.resolve()), alias).replace(str(path), alias)
            (out / (label + "-" + name + ".log")).write_text(safe, encoding="utf-8")
            result[name + "_exit"] = code
            return code, output

        binary = str(sdk / "bin/flutter")
        dart = str(sdk / "bin/cache/dart-sdk/bin/dart")
        pub = [dart, "pub", "get", "--offline", "--enforce-lockfile"]
        rc, _ = record("original-lock", pub)
        if rc == 0:
            raise RuntimeError("the original lock now resolves; recheck the test fixture")
        subprocess.run(["git", "apply", str(OUT / "test-lock.patch")], cwd=repo, check=True)
        test_lock = hashlib.sha256((repo / "pubspec.lock").read_bytes()).hexdigest()
        result["test_lock_sha256"] = test_lock
        rc, _ = record("dependencies", [binary, "--no-version-check", "pub", "get",
                                      "--offline", "--enforce-lockfile"])
        if rc:
            return result
        if hashlib.sha256((repo / "pubspec.lock").read_bytes()).hexdigest() != test_lock:
            raise RuntimeError("pub changed the locked dependency versions")
        shutil.copytree(repo / "signaling", temp / "signaling")
        (temp / "signaling/flutter_suite_listener_test.go").write_text(LISTENER)
        rc, output = record("listener-build", ["go", "test", "-trimpath", "-c", "-o",
                            str(temp / "listener"), "."], temp / "signaling")
        if rc:
            return result
        # Fail if this port already belongs to a process outside this run.
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(("127.0.0.1", 9901))
        server = subprocess.Popen([str(temp / "listener"), "-test.run", "^TestLocalFlutterSuiteListener$"],
                                  cwd=temp, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError("local signaling listener exited before readiness")
                try:
                    with socket.create_connection(("127.0.0.1", 9901), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise RuntimeError("loopback listener failed readiness")
            rc, output = record("tests", [binary, "--no-version-check", "test", "--no-pub", "--concurrency=1",
                                "--reporter=expanded"])
            for line in reversed(output.splitlines()):
                match = CLOCK.match(line)
                if match:
                    result["reported_pass"], result["reported_skip"], result["reported_fail"] = [
                        int(value or 0) for value in match.groups()]
                    break
        finally:
            server.terminate()
            server.wait(timeout=10)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ["baseline", "candidate", "sdk", "pub-cache"]:
        parser.add_argument("--" + flag, required=True, type=Path)
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    pinned = json.loads((args.baseline / ".fvmrc").read_text())["flutter"]
    version = json.loads((args.sdk / "bin/cache/flutter.version.json").read_text())["frameworkVersion"]
    if pinned != version or json.loads((args.candidate / ".fvmrc").read_text())["flutter"] != version:
        raise RuntimeError("SDK and both .fvmrc versions must match")
    summary = {"sdk": version}
    for label, repo in [("before", args.baseline), ("after", args.candidate)]:
        lock_file = repo / "pubspec.lock"
        original = subprocess.check_output(["git", "show", "HEAD:pubspec.lock"], cwd=repo)
        if lock_file.read_bytes() != original:
            raise RuntimeError("provide a checkout with its original pubspec.lock")
        try:
            summary[label] = suite(label, repo.resolve(), args.sdk.resolve(), args.pub_cache.resolve(), args.out)
        finally:
            lock_file.write_bytes(original)
        print(label, summary[label], flush=True)
        (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return not all(summary[label].get("tests_exit") == 0 for label in ["before", "after"])


if __name__ == "__main__":
    raise SystemExit(main())
