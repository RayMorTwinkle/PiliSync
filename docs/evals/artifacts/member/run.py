"""Run the same fixtures against the real member coordinator in another checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("checkout", type=Path)
parser.add_argument("--dart", default="dart")
args = parser.parse_args()
repo = args.checkout.resolve()
harness = Path(__file__).with_name("replay.dart").resolve()
source = repo / "lib/services/watch_together"
with tempfile.TemporaryDirectory() as tmp:
    config = Path(tmp) / "package_config.json"
    # The four pure-Dart production files use Dart 3 syntax and no plugins.
    # Map package:PiliPlus to the checkout without modifying its Pub lock.
    config.write_text(json.dumps({"configVersion": 2, "packages": [
        {"name": "PiliPlus", "rootUri": repo.as_uri() + "/", "packageUri": "lib/",
         "languageVersion": "3.0"}
    ]}))
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()
    inputs = {name: sha(source / name) for name in
              ("wt_member_coordinator.dart", "wt_models.dart", "wt_player_port.dart", "wt_sync_logic.dart")}
    info = {"revision": subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip(),
            "dart": subprocess.check_output([args.dart, "--version"], text=True, stderr=subprocess.STDOUT).strip(),
            "fixtures_sha256": sha(harness), "source_sha256": inputs}
    print(json.dumps(info), flush=True)
    result = subprocess.run([args.dart, "--packages=" + str(config), harness])
    raise SystemExit(result.returncode)
