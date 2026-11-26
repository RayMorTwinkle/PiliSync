#!/usr/bin/env python3
"""Replay the same local WebSocket contracts against two signaling trees."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ARTIFACTS = Path(__file__).resolve().parent
ROOT = ARTIFACTS.parents[3]
FIXTURE = ROOT / "signaling/playback_contract_test.go"
CASE = re.compile(r"^\s*--- (PASS|FAIL): (TestRoomWire\w+/\S+) \(", re.MULTILINE)


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def materialize(ref, output):
    commit = git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()
    archive = git("archive", "--format=tar", commit, "--", "signaling")
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar:
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or path.parts[:1] != ("signaling",):
                raise ValueError("unexpected path in the signaling archive")
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError("unexpected non-regular file in the signaling archive")
            dest = output / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(member) as source, dest.open("wb") as target:
                shutil.copyfileobj(source, target)
    return ref + " " + commit


def digest_tree(path):
    digest = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_file():
            digest.update(file.relative_to(path).as_posix().encode() + b"\0")
            digest.update(hashlib.sha256(file.read_bytes()).digest())
    return digest.hexdigest()


def replay(label, ref, out):
    with tempfile.TemporaryDirectory(prefix="pilisync-go-") as tmp:
        tmp = Path(tmp)
        revision = materialize(ref, tmp)
        package = tmp / "signaling"
        shutil.copyfile(FIXTURE, package / FIXTURE.name)
        tree = digest_tree(package)
        env = dict(os.environ, GOWORK="off", GOPROXY="off", GOTOOLCHAIN="local")
        commands = [
            ("existing", ["go", "test", "-trimpath", "-count=1", "-skip", "^TestRoomWire", "./..."]),
            ("contracts", ["go", "test", "-trimpath", "-race", "-count=1", "-run", "^TestRoomWire", "-v", "."]),
        ]
        result = {"revision": revision, "tested_tree_sha256": tree}
        for group, args in commands:
            run = subprocess.run(args, cwd=package, env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True)
            preamble = "\n".join([
                revision,
                "tested signaling tree sha256: " + tree,
                "fixture sha256: " + hashlib.sha256(FIXTURE.read_bytes()).hexdigest(),
                subprocess.check_output(["go", "version"], text=True).strip(),
                "$ " + " ".join(args),
                "",
            ])
            (out / (label + "-" + group + ".log")).write_text(
                preamble + run.stdout + f"\nexit={run.returncode}\n", encoding="utf-8")
            result[group + "_exit"] = run.returncode
            if group == "contracts":
                result["cases"] = {name: outcome for outcome, name in CASE.findall(run.stdout)}
                result["passed"] = sum(value == "PASS" for value in result["cases"].values())
                result["total"] = len(result["cases"])
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="backup1126")
    parser.add_argument("--candidate", default="refactor/1126")
    parser.add_argument("--out", default=str(ARTIFACTS), type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    result = {}
    for label, ref in [("before", args.baseline), ("after", args.candidate)]:
        result[label] = replay(label, ref, args.out)
        print(label, len(result[label]["cases"]), "cases", flush=True)
    (args.out / "summary.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    before, after = result["before"], result["after"]
    return not (before["existing_exit"] == after["existing_exit"] == 0 and
                before["cases"] and before["cases"].keys() == after["cases"].keys() and
                after["contracts_exit"] == 0 and all(value == "PASS" for value in after["cases"].values()))


if __name__ == "__main__":
    raise SystemExit(main())
