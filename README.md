# `omarchy audio tuning fronted-sink` is blind to hand-installed tunings

In [Omarchy](https://github.com/omacom/omarchy), a speaker tuning is a virtual sink in front of the real
speakers. `omarchy audio tuning fronted-sink` answers "which physical sink is the tuning fronting", and
two consumers use that answer to keep the physical sink out of the audio panel:

- `omarchy-audio-sink-availability` reports it unavailable;
- `omarchy-audio-output-switch` skips it when rotating outputs.

`docs/audio-tuning.md` states that contract unconditionally: *"The fronted sink is hidden. The tuning and
the physical speakers both exist in the graph, and selecting the physical one would only bypass the
tuning."*

The command answers from the **shipped** tuning that matches the machine — `tuned_hardware_sink()` reads
`sink_pattern` out of a directory under `default/audio/tunings`. A tuning installed by hand has no such
directory, so while that tuning is installed and fronting, the command prints nothing and exits 1:

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

Selecting that sink bypasses the tuning, which is the opposite of what the command exists for.

The resolution the command needs already exists in the same script: `tuning_downstream_sink()`, which is
`omarchy-audio-output-sink` following the filter-chain's own output stream down to the sink underneath —
and it answers correctly on the very machine above:

```
$ omarchy audio output sink omarchy_speaker_tuning
alsa_output.pci-0000_00_1b.0.analog-stereo
```

## The fix

One file, `bin/omarchy-audio-tuning`: a new `fronted_physical_sink()` that keeps the shipped tuning's
declaration as the first answer — it is the most precise one — and falls back to the running graph when
there is none. Used by `fronted-sink` and by `off`, which had the same root cause: removing a
hand-installed tuning left the default sink pointing at a sink that no longer existed, because the same
lookup failed and there was no physical sink to restore it to.

```
bin/omarchy-audio-tuning | 28 ++++++++++++++++++++++++++--
1 file changed, 26 insertions(+), 2 deletions(-)
```

The guard is the part worth reviewing: while the chain is idle or unlinked, `omarchy-audio-output-sink`
falls back to printing the sink it was given, and reporting `omarchy_speaker_tuning` as the sink to hide
would hide the only speaker entry there is. The helper returns 1 in that case, so the behaviour is "no
answer" rather than a wrong one.

## Proof

`proof/proof.txt` was captured on the machine that hit this, with a hand-installed tuning and no shipped
match. `proof/run-proof.sh` reproduces it and touches nothing: the patched script is exercised through a
`PATH` shim with `OMARCHY_PATH=/usr/share/omarchy`, and no file under `/usr/share/omarchy` is modified.

| Check | Result |
| --- | --- |
| installed script, unchanged | prints nothing, exit 1 |
| patched script, live graph | `alsa_output.pci-0000_00_1b.0.analog-stereo`, exit 0 |
| patched script, resolver stubbed to the idle answer | prints nothing, exit 1 (the guard holds) |
| `omarchy-audio-sink-availability`, patched | tuning `1`, physical `0` |
| `omarchy-audio-sink-availability`, unpatched | tuning `1`, physical `1` |
| output switcher's own `jq` filter, patched | only the tuning sink is a rotation stop |
| the same filter with the unpatched answer | the physical sink is a rotation stop too |

![no](https://img.shields.io/badge/audio-not%20touched-informational) The proof never calls
`omarchy-audio-output-switch`: that script does not print, it *switches*, and calling it as a probe moves
your default sink. `proof/proof.txt` records that an earlier revision of the script made exactly that
mistake, and the filter is now evaluated directly instead.

This public copy is self-contained: the patched script ships as `bin/omarchy-audio-tuning` (the same
path upstream uses), and `proof/run-proof.sh` reads it from there, builds its own `PATH` shims at run
time, and writes a fresh `proof/proof.txt`. That is how the transcript committed here was produced. The
shim directories are regenerated on each run and are gitignored.

## Pull request

Opened as **https://github.com/omacom/omarchy/pull/12842** — branch `fix/fronted-sink-fallback` off
`quattro`, one commit, one file (`bin/omarchy-audio-tuning`, +26/-2). The patch is also here as
`0001-fix-audio-resolve-the-fronted-sink-from-the-running-.patch`, and `commit-message.txt` is the
message it was generated with. The PR body, which doubles as a bug report if an issue is wanted first:

> `omarchy audio tuning fronted-sink` answers from the shipped tuning that matches the machine
> (`tuned_hardware_sink` -> `sink_pattern`). A tuning installed by hand has no directory under
> `default/audio/tunings`, so the command printed nothing and exited 1 while that tuning was installed
> and fronting.
>
> Both callers then stopped hiding the physical sink: `omarchy-audio-sink-availability` reported it
> available and `omarchy-audio-output-switch` kept it as a rotation stop, so picking it bypasses the
> tuning — the opposite of what `docs/audio-tuning.md` promises, and that promise is not qualified by
> where the tuning came from.
>
> This resolves the physical sink from the tuning's own output stream when no shipped tuning answers,
> reusing `tuning_downstream_sink()`: the declaration stays the first answer, the graph is the fallback.
> `off` had the same root cause — it left the default sink pointing at a sink that no longer existed
> after removing a hand-installed tuning — and now uses the same resolution.
>
> The guard is the part worth reviewing: while the chain is idle or unlinked, `omarchy-audio-output-sink`
> answers with the sink it was given, and reporting the tuning sink as the sink to hide would hide the
> only speaker entry there is.
>
> Proof on hardware with a hand-installed tuning and no shipped match: `fronted-sink` prints
> `alsa_output.pci-0000_00_1b.0.analog-stereo` and exits 0 (it printed nothing and exited 1 before);
> `omarchy-audio-sink-availability` reports the physical sink `0` and the tuning `1`; with the resolver
> stubbed to the idle answer it still exits 1. Docs untouched: `docs/audio-tuning.md` already describes
> this behaviour.
>
> Not included, and deliberately: making a hand-installed tuning first-class, e.g. reading
> `~/.config/omarchy/audio/tunings/` in `tuning_match`. That would be the better home for the
> declaration and would make this fallback less load-bearing; it is a bigger change and I did not want to
> bundle it.

## Honest limits

- The unlinked case still answers nothing, so the documented promise is repaired only while the chain is
  actually up. That is deliberate: an unlinked chain is not fronting anything, and the physical sink is
  then the only path that carries audio.
- It costs one extra `pactl list sink-inputs` per call, and only when a tuning is installed without a
  shipped match.
- This treats the symptom of hand-installed tunings not being first class; it does not remove that.
