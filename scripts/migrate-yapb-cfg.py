#!/usr/bin/env python3
"""Rewrite a fleet member's live yapb.cfg from the new image's stock file, keeping
the operator's tuned values.

    scripts/migrate-yapb-cfg.py <server-name> [--image rehlds-csserver:local] [--dry-run]

Run from the compose directory while the server's OLD container is still
running: its baked stock cfg (/opt/cs16/serverfiles-base/...) is the baseline
that defines "tuned" (any cvar whose live value differs from it). The new stock
cfg is read from the freshly built image. Cvars that no longer exist upstream
are reported and dropped; new cvars take their stock values. The live file is
copied to yapb.cfg.bak-<date> first. Then: docker compose up -d <server-name>.
"""
import argparse, datetime, pathlib, re, shutil, subprocess, sys

CFG = "/opt/cs16/serverfiles-base/cstrike/addons/yapb/conf/yapb.cfg"
LINE = re.compile(r'^(\s*)(yb_[a-z0-9_]+)(\s+)"([^"]*)"(.*)$')


def parse(text):
    return {m.group(2): m.group(4) for m in map(LINE.match, text.splitlines()) if m}


def run(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--image", default="rehlds-csserver:local")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    live_path = pathlib.Path("serverdata") / a.name / "cstrike/addons/yapb/conf/yapb.cfg"
    if not live_path.is_file():
        sys.exit(f"no live cfg at {live_path} (run from the compose directory)")
    old_stock = run("docker", "exec", a.name, "cat", CFG)
    new_stock = run("docker", "run", "--rm", "--entrypoint", "cat", a.image, CFG)
    live = live_path.read_text()

    old_vals, new_vals, live_vals = parse(old_stock), parse(new_stock), parse(live)
    tuned = {k: v for k, v in live_vals.items() if old_vals.get(k) != v}
    kept = {k: v for k, v in tuned.items() if k in new_vals}
    dropped = {k: v for k, v in tuned.items() if k not in new_vals}

    out = []
    for line in new_stock.splitlines():
        m = LINE.match(line)
        if m and m.group(2) in kept:
            line = f'{m.group(1)}{m.group(2)}{m.group(3)}"{kept[m.group(2)]}"{m.group(5)}'
        out.append(line)
    result = "\n".join(out) + "\n"

    print(f"{a.name}: old stock {len(old_vals)} cvars, new stock {len(new_vals)}, live {len(live_vals)}")
    print(f"tuned values carried over ({len(kept)}):")
    for k, v in sorted(kept.items()):
        print(f"  {k:<30} {v:<10} (stock {new_vals[k]})")
    if dropped:
        print(f"tuned values DROPPED, cvar gone upstream ({len(dropped)}):")
        for k, v in sorted(dropped.items()):
            print(f"  {k:<30} {v}")
    gone = sorted(set(live_vals) - set(new_vals))
    new = sorted(set(new_vals) - set(live_vals))
    print(f"cvars removed upstream: {len(gone)}; new at stock: {len(new)}")
    if a.dry_run:
        print("dry run: nothing written")
        return
    backup = live_path.with_name(f"yapb.cfg.bak-{datetime.date.today().isoformat()}")
    shutil.copy2(live_path, backup)
    live_path.write_text(result)
    check = parse(live_path.read_text())
    assert all(check[k] == v for k, v in kept.items()), "verification failed"
    print(f"written {live_path} (backup {backup}); verified {len(kept)} tuned values")


if __name__ == "__main__":
    main()
