#!/usr/bin/env bash
# Install the dv-mkv-to-mp4 skill into the opencode skills directory.
#
#   bash install.sh              install into ~/.config/opencode/skills
#   bash install.sh /some/dir    install into /some/dir/skills
#
# The skill is copied, not moved, so the repository keeps working as a clone.
set -uo pipefail

SKILL_ID="dv-mkv-to-mp4"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/.opencode/skills/$SKILL_ID"

if [[ ! -f "$SOURCE/SKILL.md" ]]; then
  printf 'ERROR: skill not found at %s\n' "$SOURCE" >&2
  exit 1
fi

# On Windows opencode keeps its config under the native user profile, which is
# not the same place as the cygwin home: cygwin HOME is /home/<user>, which
# maps to C:\cygwin64\home\<user>. USERPROFILE is the reliable source, and on
# Linux and macOS it is simply not set.
if [[ $# -eq 0 ]]; then
  if [[ -n "${USERPROFILE:-}" ]]; then
    SKILLS_ROOT="$(cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE")/.config/opencode/skills"
  else
    SKILLS_ROOT="$HOME/.config/opencode/skills"
  fi
else
  SKILLS_ROOT="$1"
fi

TARGET="$SKILLS_ROOT/$SKILL_ID"

if [[ -e "$TARGET" ]]; then
  printf 'ERROR: %s already exists, remove it first\n' "$TARGET" >&2
  exit 1
fi

mkdir -p "$SKILLS_ROOT" || { printf 'ERROR: cannot create %s\n' "$SKILLS_ROOT" >&2; exit 1; }
cp -r "$SOURCE" "$TARGET" || { printf 'ERROR: copy failed\n' >&2; exit 1; }
chmod +x "$TARGET"/scripts/*.sh 2>/dev/null

printf 'installed %s\n' "$TARGET"
printf 'the skill id is "%s", load it with the skill tool or mention @%s\n' "$SKILL_ID" "$SKILL_ID"
