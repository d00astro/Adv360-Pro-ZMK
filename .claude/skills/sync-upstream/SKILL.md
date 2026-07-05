---
name: sync-upstream
description: Sync this fork with KinesisCorporation upstream — fetch, merge into engrammer, push, and rebuild firmware. Use when asked to merge/pull upstream changes, update the ZMK firmware, fix GitHub ahead/behind counts, resolve README merge conflicts, or explain this repo's branching strategy.
---

Personal ZMK config fork (the "engrammer" layout) of
KinesisCorporation/Adv360-Pro-ZMK. Upstream syncs are driven by
`.claude/skills/sync-upstream/sync.sh`, which executes the whole
branching policy below and is safe to re-run (idempotent when up to
date). All paths are relative to the repo root.

## Branching model

```
upstream/V3.0 ──ff-only──▶ KinesisCorporation-V3.0 ──merge-only──▶ engrammer ──▶ CI build ──▶ flash
                           (landing branch,                        (default branch,
                            mirrors upstream exactly)               all personal config)
```

Only these two long-lived branches exist. The rules:

- **`engrammer`** is the default branch and the only build/flash source.
  It advances by direct commits and by **merges** from the landing
  branch. **Never rebase it, never use GitHub's "Sync fork" button** —
  both forge new SHAs and desync the fork counter (see Gotchas).
- **`KinesisCorporation-V3.0`** mirrors upstream `V3.0` exactly.
  Fast-forward only; never commit to it. Its value: `git diff
  KinesisCorporation-V3.0 engrammer` shows exactly the personal
  customizations, and its CI artifacts are vanilla firmware for
  debugging.
- Risky changes go on short-lived branches off `engrammer` (CI builds
  every pushed branch → test-flash the artifact → merge → **delete the
  branch**).
- After flashing and confirming a good state:
  `git tag flashed-$(date +%Y%m%d) && git push origin --tags`.

## Sync with upstream (agent path)

```bash
.claude/skills/sync-upstream/sync.sh          # local sync, shows what happened
.claude/skills/sync-upstream/sync.sh --push   # …then push + trigger CI firmware build
```

The script: fetches upstream → fast-forwards the landing branch (fails
loudly if it diverged) → merges into `engrammer` → verifies whether
`config/` (the keymap) was touched → reports SHA-based ahead/behind vs
upstream → reports the latest commit on the pinned firmware branch.

Equivalent manual commands:

```bash
git fetch upstream
git fetch . upstream/V3.0:KinesisCorporation-V3.0
git merge KinesisCorporation-V3.0
git push origin engrammer KinesisCorporation-V3.0
```

## Firmware updates: merging is NOT enough

This repo contains no firmware — only the keymap and a build recipe.
`config/west.yml` pins the real ZMK source: branch `adv360-z3.5-2` of
`github.com/refil/zmk`. That is a **moving branch**; two separate
channels deliver firmware updates:

1. **Pin changes** in `west.yml` (rare, ~yearly) — arrive via the merge
   above.
2. **New commits on the pinned branch** — invisible to git in this
   repo. Picked up only at build time (CI runs `west update` on every
   build).

So to actually update the keyboard: **push, then download the `.uf2`
artifacts from the GitHub Actions run (`firmware-no-clique` or
`firmware-clique`) and flash both halves.** A rebuild is worthwhile
even when a merge brings in nothing.

Check for new firmware without building:

```bash
curl -s "https://api.github.com/repos/refil/zmk/commits?sha=adv360-z3.5-2&per_page=5" \
  | grep -E '"(sha|date|message)"' | head -20
```

Local `make` builds cache `west update` in a Docker layer keyed on
`west.yml` — run `make clean_image` first or the ZMK checkout is
silently stale. (CI does not have this problem.)

## Gotchas

- **GitHub "Sync fork" rebases.** Used once (2026-07): it copied 3
  upstream commits onto `engrammer` with new SHAs, leaving the fork "3
  commits behind" forever despite identical content — ahead/behind
  counts compare SHAs, not content. Fix (verified): merge the landing
  branch (`git merge KinesisCorporation-V3.0`) — a content no-op that
  stitches the original SHAs into ancestry; behind → 0. The sync
  script warns when this state is detected.
- **README.md is fully personalized — keep ours on conflict.** Upstream
  touches its README ~2×/year. On conflict:
  `git checkout --ours -- README.md && git add README.md && git merge --continue`.
  But first read what they changed (`git log -p HEAD..KinesisCorporation-V3.0 -- README.md`)
  — upstream README edits sometimes document new config options worth
  folding into ours. Never apply `--ours` wholesale to `config/` or
  `.github/workflows/` — those need real merges.
- **No `gh`, `jq`, or `python3` on this machine.** GitHub API queries
  go through `curl` + `grep` (as in the firmware check above).

## Troubleshooting

- **"This branch is N commits behind KinesisCorporation:V3.0" even
  though all content is merged**: rebase-forged duplicate SHAs (see
  Gotchas). Diagnose with
  `git rev-list --left-right --count engrammer...upstream/V3.0`;
  fix with `git merge KinesisCorporation-V3.0 && git push`.
- **`sync.sh`: "KinesisCorporation-V3.0 did not fast-forward"**:
  someone committed to the landing branch. Inspect
  `git log upstream/V3.0..KinesisCorporation-V3.0`; move anything
  valuable to `engrammer`, then reset the landing branch to mirror
  upstream: `git branch -f KinesisCorporation-V3.0 upstream/V3.0`.
