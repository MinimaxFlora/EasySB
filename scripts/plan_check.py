#!/usr/bin/env python
"""Run the workflow's "Plan the builds" step locally against the live releases.

jq is not installed on this box, so a shim stands in for it and answers the same four
queries the script uses. Everything else — the script itself — is read straight out of
the workflow file, so this tests the shipped logic rather than a copy of it.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/singbox-v2ray-api.yml"

JQ_SHIM = r'''#!/usr/bin/env python
import json, sys
args = sys.argv[1:]
query = args[-1]
raw = sys.stdin.read()
data = json.loads(raw) if raw.strip() else None


def emit(value):
    if isinstance(value, (dict, list)):
        print(json.dumps(value))
    elif value is None:
        print("null")
    else:
        print(value)
    sys.exit(0)


if query == ".tag_name":
    emit(data.get("tag_name"))
if query == '[.[] | select(.prerelease)][0].tag_name':
    emit(next((r["tag_name"] for r in data if r.get("prerelease")), None))
if "endswith(\".sha256\")" in query:
    emit(len([a for a in data.get("assets", []) if a["name"].endswith(".sha256")]))
if query.startswith(". + [{"):
    channel = args[args.index("--arg") + 2]
    tag = args[args.index("--arg", args.index("--arg") + 1) + 2]
    version = args[args.index("--arg", args.index("--arg", args.index("--arg") + 1) + 1) + 2]
    emit(data + [{"channel": channel, "tag": tag, "version": version}])
raise SystemExit(f"unsupported query: {query}")
'''


def main() -> int:
    spec = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    step = next(
        s for s in spec["jobs"]["resolve"]["steps"] if s.get("name") == "Plan the builds"
    )
    script = step["run"]

    # Keep the scratch directory inside the repo: MSYS bash and native python disagree
    # about what /tmp means, and the shim has to be reachable by both.
    tmp = WORKFLOW.parents[2] / ".tmp-plan"
    pass  # keep for inspection
    tmp.mkdir(parents=True, exist_ok=True)
    msys = str(tmp).replace("\\", "/")  # native form: bash execs it, python opens it
    shim = tmp / "jq"
    shim.write_text(JQ_SHIM, encoding="utf-8")
    os.chmod(shim, 0o755)
    script = script.replace("jq ", f"{msys}/jq ")
    script_file = tmp / "plan.sh"
    script_file.write_text(script, encoding="utf-8")

    out = tmp / "github_output"
    out.write_text("", encoding="utf-8")
    env = dict(os.environ)
    env.update(
        {
            "PATH": env["PATH"],
            "UPSTREAM": "SagerNet/sing-box",
            "EXTRA_TAG": "with_v2ray_api",
            "GITHUB_REPOSITORY": "MinimaxFlora/EasySB",
            "ARCHES": "amd64 arm64 armv7 armv6 386 riscv64 s390x",
            "GITHUB_OUTPUT": str(out),
            "WANTED": os.environ.get("WANTED", "both"),
            "FORCE": os.environ.get("FORCE", "false"),
        }
    )
    proc = subprocess.run(["bash", str(script_file)], env=env, capture_output=True, text=True)
    print(proc.stdout, end="")
    if proc.returncode:
        print(proc.stderr, file=sys.stderr, end="")
        return proc.returncode
    targets = out.read_text(encoding="utf-8").strip().removeprefix("targets=")
    print("targets =", targets)
    decided = json.loads(targets)
    if os.environ.get("EXPECT_EMPTY") == "1":
        assert decided == [], f"expected no builds, got {decided}"
        print("OK: nothing to rebuild, the schedule would skip")
    pass  # keep for inspection
    return 0


if __name__ == "__main__":
    sys.exit(main())
