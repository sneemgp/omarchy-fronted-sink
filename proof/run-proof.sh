#!/bin/bash
# Proof that the patched bin/omarchy-audio-tuning fixes the fronted-sink gap on
# this machine, WITHOUT installing or replacing anything in /usr/share/omarchy.
#
# Three checks, all read-only against the live audio graph:
#   P0  the installed (unpatched) script fails: nothing printed, exit 1
#   P1  the patched script resolves the physical sink the tuning fronts, exit 0
#   P2  with the resolver stubbed to answer "the tuning sink itself" -- what it
#       returns while the chain is idle or unlinked -- the guard still exits 1
#   P3  end to end: omarchy-audio-sink-availability, driven by the patched script
#       through a PATH shim, reports the physical sink unavailable and the tuning
#       sink available; and the output switcher's filter, evaluated read-only,
#       drops the physical sink from the rotation
#
# Usage: ./run-proof.sh    (writes proof.txt next to this script)
#
# Do NOT call omarchy-audio-output-switch from here. It never prints: it switches.
# An earlier revision of this script called it, and it moved this machine's default
# sink from the physical output to the tuning sink. It was restored with
# `omarchy audio output set default <id> <name>`.  The filter is evaluated directly instead.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
system="${OMARCHY_PATH:-/usr/share/omarchy}"
patched="$here/../bin/omarchy-audio-tuning"

[[ -x $patched ]] || { echo "patched script not found: $patched" >&2; exit 1; }

shim="$here/bin"
idle="$here/bin-idle"
rm -rf "$shim" "$idle"
mkdir -p "$shim" "$idle"
ln -sf "$patched" "$shim/omarchy-audio-tuning"
ln -sf "$patched" "$idle/omarchy-audio-tuning"

# A resolver stub for the idle/unlinked case: omarchy-audio-output-sink falls back
# to printing the sink itself when it cannot follow the chain downstream.
cat > "$idle/omarchy-audio-output-sink" <<'STUB'
#!/bin/bash
# Stub: simulates "nothing resolvable downstream", the answer the real resolver
# gives while the tuning chain is idle or unlinked. Kept as a stub on purpose --
# unlinking the live chain to test this would break the user's audio.
printf '%s\n' "${1:-omarchy_speaker_tuning}"
STUB
chmod +x "$idle/omarchy-audio-output-sink"

out="$here/proof.txt"
{
  echo "# Proof: patched omarchy-audio-tuning resolves the fronted sink on this machine"
  echo "# captured: $(date -Is) on $(hostname), kernel $(uname -r)"
  echo "# script under test : $patched"
  echo "# installed script  : $system/bin/omarchy-audio-tuning"
  echo "# commit            : $(git -C "$here/../repo" rev-parse HEAD) on $(git -C "$here/../repo" rev-parse --abbrev-ref HEAD)"
  echo
  echo "## setup"
  echo "\$ omarchy audio tuning status        # a hand-installed tuning, no shipped one matches"
  omarchy audio tuning status 2>&1 || true
  echo
  echo "\$ pactl list sinks short"
  pactl list sinks short 2>&1
  echo
  echo "## P0 -- installed script, unpatched"
  echo "\$ omarchy audio tuning fronted-sink ; echo exit=\$?"
  omarchy audio tuning fronted-sink 2>&1; echo "exit=$?"
  echo "# -> prints nothing: callers cannot hide the physical sink, so selecting it"
  echo "#    bypasses the tuning."
  echo
  echo "## P1 -- patched script, live graph"
  echo "\$ OMARCHY_PATH=$system PATH=$shim:\$PATH omarchy-audio-tuning fronted-sink ; echo exit=\$?"
  OMARCHY_PATH="$system" PATH="$shim:$PATH" omarchy-audio-tuning fronted-sink 2>&1; echo "exit=$?"
  echo "# -> prints the physical sink the tuning feeds, and nothing else."
  echo
  echo "## P2 -- patched script, resolver stubbed to the idle/unlinked answer"
  echo "\$ OMARCHY_PATH=$system PATH=$idle:\$PATH omarchy-audio-tuning fronted-sink ; echo exit=\$?"
  OMARCHY_PATH="$system" PATH="$idle:$PATH" omarchy-audio-tuning fronted-sink 2>&1; echo "exit=$?"
  echo "# -> exits 1 with no output: the tuning sink is never reported as the sink"
  echo "#    to hide, which would have been worse than the bug."
  echo
  echo "## P3 -- end to end: the consumers that hide the sink"
  echo "\$ PATH=$shim:\$PATH omarchy-audio-sink-availability"
  PATH="$shim:$PATH" omarchy-audio-sink-availability 2>&1
  echo
  echo "\$ omarchy-audio-sink-availability      # unpatched, for contrast"
  omarchy-audio-sink-availability 2>&1
  echo
  echo "## P3b -- the output switcher's filter, evaluated read-only"
  echo "# omarchy-audio-output-switch does not print: it switches, so running it here"
  echo "# would move the user's default sink. Its jq filter is applied to the same"
  echo "# pactl JSON instead, once with the patched answer and once with the empty"
  echo "# answer the unpatched script gives."
  fronted_patched="$(OMARCHY_PATH="$system" PATH="$shim:$PATH" omarchy-audio-tuning fronted-sink 2>/dev/null || true)"
  echo "\$ fronted='$fronted_patched'"
  echo "\$ pactl -f json list sinks | jq --arg fronted \"\$fronted\" '<switch filter>' | jq -r '.[].name'"
  timeout 2 pactl -f json list sinks 2>/dev/null | jq --arg fronted "$fronted_patched" '[.[]
      | select((.ports | length == 0) or ([.ports[]? | .availability != "not available"] | any))
      | select($fronted == "" or .name != $fronted)]' 2>/dev/null | jq -r '.[].name' 2>/dev/null
  echo "\$ fronted=''   # what callers get before the fix"
  timeout 2 pactl -f json list sinks 2>/dev/null | jq --arg fronted "" '[.[]
      | select((.ports | length == 0) or ([.ports[]? | .availability != "not available"] | any))
      | select($fronted == "" or .name != $fronted)]' 2>/dev/null | jq -r '.[].name' 2>/dev/null
  echo "# -> with the fix the physical sink is not a rotation stop; without it, it is."
} > "$out" 2>&1

cat "$out"
