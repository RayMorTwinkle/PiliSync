"""Compare pre-existing tracked paths by Git type, mode and object ID; no blob reads."""
import argparse
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[4]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("before", nargs="?", default="backup1126")
parser.add_argument("after", nargs="?", default="HEAD")
args = parser.parse_args()

def tree(ref):
    commit = subprocess.check_output(
        ["git", "-C", root, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}"],
        text=True).strip()
    entries = subprocess.check_output(["git", "-C", root, "ls-tree", "-rz", commit])
    pairs = [line.split(b"\t", 1) for line in entries.split(b"\0") if line]
    return commit, {path.decode(): meta for meta, path in pairs}

before, original = tree(args.before)
after, current = tree(args.after)
removed = sorted(original.keys() - current.keys())
changed = sorted(path for path in original.keys() & current.keys() if original[path] != current[path])
allowed = {"README.md", "lib/services/watch_together/wt_member_coordinator.dart"}
unexpected = sorted(set(changed) - allowed)
print(json.dumps({"before": before, "after": after, "removed": removed,
                  "changed_existing": changed, "unexpected_existing": unexpected},
                 ensure_ascii=False, indent=2))
raise SystemExit(bool(removed or unexpected))
