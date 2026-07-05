#!/usr/bin/env bash
# Sync the engrammer fork with KinesisCorporation upstream.
# Safe to re-run: every step is a no-op when already up to date.
# Usage: .claude/skills/sync-upstream/sync.sh [--push]
set -euo pipefail

cd "$(cd "$(dirname "$0")/../../.." && pwd)"

UPSTREAM_REF=upstream/V3.0
LANDING=KinesisCorporation-V3.0
MAIN=engrammer

PUSH=false
[[ "${1:-}" == "--push" ]] && PUSH=true

# Preconditions: clean tree, on the personal branch
[[ -z "$(git status --porcelain)" ]] || { echo "ERROR: working tree not clean — commit or stash first."; exit 1; }
[[ "$(git branch --show-current)" == "$MAIN" ]] || { echo "ERROR: not on $MAIN (run: git switch $MAIN)"; exit 1; }

echo "==> Fetching upstream..."
git fetch upstream

# Fast-forward the landing branch. This FAILS if the landing branch has
# local commits — it must always mirror upstream exactly. Never force it.
echo "==> Fast-forwarding $LANDING to $UPSTREAM_REF..."
git fetch . "$UPSTREAM_REF:$LANDING" || {
  echo "ERROR: $LANDING did not fast-forward. It has commits that are not in upstream."
  echo "       It must mirror upstream exactly — inspect: git log $UPSTREAM_REF..$LANDING"
  exit 1
}

if git merge-base --is-ancestor "$LANDING" "$MAIN"; then
  echo "==> Already up to date with upstream."
else
  echo "==> Incoming upstream changes:"
  git log --oneline "$MAIN..$LANDING"
  git diff --stat "$MAIN...$LANDING"
  echo "==> Merging (merge-only policy — never rebase $MAIN)..."
  # On a README.md conflict: keep ours, but read their diff first (see SKILL.md)
  git merge "$LANDING" -m "chore: merge upstream V3.0"
  if git diff --quiet HEAD^1 HEAD -- config/; then
    echo "OK: config/ (keymap) untouched by this merge."
  else
    echo "NOTE: merge changed files under config/ — review before flashing:"
    git diff --stat HEAD^1 HEAD -- config/
  fi
fi

# Ahead/behind is SHA-based. behind>0 after a merge means duplicated
# commits from a rebase-style sync — see SKILL.md gotchas.
read -r ahead behind <<<"$(git rev-list --left-right --count "$MAIN...$UPSTREAM_REF")"
echo "==> $MAIN: $ahead ahead, $behind behind $UPSTREAM_REF"
[[ "$behind" == "0" ]] || echo "WARNING: still behind upstream — merge $LANDING again to reconcile (SKILL.md: gotchas)."

# Informational: the actual firmware is the tip of a MOVING branch in
# refil/zmk, pinned by name in config/west.yml. New commits there arrive
# only via rebuild+reflash, never via this repo.
PIN=$(sed -n 's/^ *revision: *//p' config/west.yml | head -1)
echo "==> Firmware pin: refil/zmk@$PIN — latest upstream firmware commit:"
curl -sf --max-time 10 "https://api.github.com/repos/refil/zmk/commits?sha=$PIN&per_page=1" \
  | grep -E -m2 '"(sha|date)"' | head -2 || echo "    (API unreachable — skipped)"

if $PUSH; then
  echo "==> Pushing $MAIN and $LANDING..."
  git push origin "$MAIN" "$LANDING"
  echo "Done. CI is building fresh firmware — download the .uf2 artifacts from the"
  echo "GitHub Actions run and flash BOTH halves to actually apply firmware updates."
else
  echo "Done (local only). Re-run with --push to publish and trigger the CI firmware build."
fi
