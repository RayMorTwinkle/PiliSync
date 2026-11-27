#!/usr/bin/env python3
"""Apply the repository's macOS patch set to explicitly supplied sandbox copies."""
import argparse
from pathlib import Path
import subprocess

SDK_PATCHES = (
    "modal_barrier text_selection mouse_cursor image_anim layout_builder navigation_drawer "
    "popup_menu fab null_safety_for_selectable_region selectable_region editable_text text_field "
    "scroll_position scrollable scrollable_gesture draggable_scrollable_sheet scaffold text "
    "text_painter sliver refresh_indicator"
).split()
MATERIAL_PATCHES = (
    "modal_barrier_material navigation_drawer popup_menu fab text_field scaffold refresh_indicator tabs"
).split()


def apply(root, patches, names):
    for name in names:
        data = (patches / (name + ".patch")).read_bytes().replace(b"\r\n", b"\n")
        cmd = ["git", "apply", "--whitespace=nowarn"]
        pending = subprocess.run(cmd + ["--check", "-"], cwd=root, input=data, capture_output=True)
        if pending.returncode == 0:
            subprocess.run(cmd + ["-"], cwd=root, input=data, check=True)
            print(name, "applied")
        elif subprocess.run(cmd + ["--reverse", "--check", "-"], cwd=root, input=data,
                            capture_output=True).returncode == 0:
            print(name, "already applied")
        else:
            raise SystemExit(name + ": " + pending.stderr.decode())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--material-cache", type=Path)
    args = parser.parse_args()
    if not (args.sdk or args.material_cache):
        parser.error("provide an isolated SDK or material_ui cache directory")
    patches = args.repo.resolve() / "lib/scripts"
    if args.sdk:
        apply(args.sdk.resolve(), patches, SDK_PATCHES)
    if args.material_cache:
        apply(args.material_cache.resolve(), patches / "material", MATERIAL_PATCHES)
