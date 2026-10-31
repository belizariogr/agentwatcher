#!/usr/bin/env python3
"""Send the macOS signing and notarization credentials to GitHub Secrets.

Reads a .env (default: ./.env, falling back to ../bgdesk/.env) and never
prints values. Without --apply it only lists what would be sent.

  scripts/setup-github-secrets.py [--env-file PATH] [--apply]
"""
import argparse
import base64
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = ("MACOS_P12_BASE64", "MACOS_P12_PASSWORD", "MACOS_NOTARY_APPLE_ID", "MACOS_NOTARY_PASSWORD")


def dotenv(path):
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.removeprefix("export ").split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default="belizariogr/agentwatcher")
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--apply", action="store_true", help="upload; without it only names are shown")
    args = parser.parse_args()

    env_file = args.env_file or next((p for p in (ROOT / ".env", ROOT.parent / "bgdesk/.env") if p.exists()), None)
    if env_file is None:
        raise SystemExit("No .env found; pass --env-file")
    values = {**dotenv(env_file), **{k: v for k, v in os.environ.items() if k.startswith("MACOS_")}}
    print(f"Reading {env_file}" + ("" if args.env_file or env_file.parent == ROOT else "  (fallback: no ./.env here)"))

    secrets = {}
    for name in ("MACOS_P12_PASSWORD", "MACOS_CODESIGN_IDENTITY", "MACOS_TEAM_ID",
                 "MACOS_NOTARY_APPLE_ID", "MACOS_NOTARY_PASSWORD"):
        if values.get(name):
            secrets[name] = values[name]
    if values.get("MACOS_P12_BASE64"):
        secrets["MACOS_P12_BASE64"] = values["MACOS_P12_BASE64"]
    elif values.get("MACOS_P12_FILE"):
        p12 = Path(values["MACOS_P12_FILE"]).expanduser()
        if not p12.is_file():
            raise SystemExit(f"MACOS_P12_FILE not found: {p12}")
        secrets["MACOS_P12_BASE64"] = base64.b64encode(p12.read_bytes()).decode()

    missing = [name for name in REQUIRED if name not in secrets]
    if missing:
        raise SystemExit("Missing in the .env: " + ", ".join(missing))

    for name, value in sorted(secrets.items()):
        if len(value.encode()) > 48 * 1024:
            raise SystemExit(f"{name}: exceeds GitHub's 48 KiB secret limit")
        if args.apply:
            subprocess.run(["gh", "secret", "set", name, "--repo", args.repo],
                           input=value, text=True, check=True, stdout=subprocess.DEVNULL)
        print(f"{name}: {'saved to GitHub' if args.apply else 'ready to send'}")
    if not args.apply:
        print("Dry run. Re-run with --apply to upload. Values are never printed.")


if __name__ == "__main__":
    main()
