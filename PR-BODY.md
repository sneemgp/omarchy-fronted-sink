`omarchy audio tuning fronted-sink` answers from the shipped tuning that matches the machine
(`tuned_hardware_sink` -> `sink_pattern` from a directory under `default/audio/tunings`). A tuning
installed by hand has no such directory, so the command printed nothing and exited 1 **while that tuning
was installed and fronting**.

Both callers then stopped hiding the physical sink: `omarchy-audio-sink-availability` reported it
available and `omarchy-audio-output-switch` kept it as a rotation stop, so selecting it bypasses the
tuning — the opposite of what `docs/audio-tuning.md` promises, and that promise is not qualified by
where the tuning came from:

```
$ omarchy audio tuning status
Installed:    yes (/home/USER/.config/pipewire/omarchy-speaker-tuning.conf.d/90-tuning.conf)
Host service: active (enabled)
Tuning sink:  present
Default sink: alsa_output.pci-0000_00_1b.0.analog-stereo
Matches:      nothing ships for this laptop

$ omarchy audio tuning fronted-sink ; echo exit=$?
exit=1

$ omarchy-audio-sink-availability
omarchy_speaker_tuning	1
alsa_output.pci-0000_00_1b.0.analog-stereo	1      <- should be 0
```

### The fix

Resolve the physical sink from the tuning's own output stream when no shipped tuning answers, reusing
`tuning_downstream_sink()` — the resolution this script already has. The declaration stays the first
answer, because it is the most precise one when it exists; the graph is the fallback, not the
replacement.

`off` had the same root cause and now uses the same resolution: removing a hand-installed tuning left the
default sink pointing at a sink that no longer existed, because the same lookup failed and there was no
physical sink to restore it to.

```diff
+fronted_physical_sink() {
+  local speakers
+  if speakers="$(tuned_hardware_sink)"; then
+    printf '%s\n' "$speakers"
+    return 0
+  fi
+  speakers="$(tuning_downstream_sink)"
+  [[ -n $speakers && $speakers != "$sink_name" ]] || return 1
+  printf '%s\n' "$speakers"
+}
```

One file: `bin/omarchy-audio-tuning`, +26/-2.

### The guard is the part worth reviewing

While the chain is idle or unlinked, `omarchy-audio-output-sink` falls back to printing the sink it was
given. Reporting `omarchy_speaker_tuning` as the sink to hide would hide the only speaker entry there
is — worse than the bug. The helper returns 1 in that case, so the answer is "no answer" rather than a
wrong one. That is also why the unlinked case still answers nothing: an unlinked chain is not fronting
anything, and the physical sink is then the only path that carries audio. It costs one extra
`pactl list sink-inputs` per call, and only when a tuning is installed without a shipped match.

### Proof on hardware

With a hand-installed tuning and no shipped match, through a `PATH` shim and
`OMARCHY_PATH=/usr/share/omarchy` — nothing under `/usr/share/omarchy` is modified:

| Check | before | after |
| --- | --- | --- |
| `omarchy audio tuning fronted-sink` | nothing, exit 1 | `alsa_output.pci-0000_00_1b.0.analog-stereo`, exit 0 |
| `omarchy-audio-sink-availability` | physical `1` | physical `0`, tuning `1` |
| the output switcher's `jq` filter | physical sink is a rotation stop | only the tuning sink is |
| resolver stubbed to the idle/unlinked answer | — | nothing, exit 1 (the guard holds) |

Docs untouched: `docs/audio-tuning.md` already describes this behaviour.

### Not included, and deliberately

Making a hand-installed tuning first class, e.g. reading `~/.config/omarchy/audio/tunings/` in
`tuning_match`. That would be the better home for the declaration, and would make this fallback less
load-bearing; it is a bigger change and I did not want to bundle it.

Evidence, the patch and a re-runnable proof also live at
https://github.com/sneemgp/omarchy-fronted-sink
