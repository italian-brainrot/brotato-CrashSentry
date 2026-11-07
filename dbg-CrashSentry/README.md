# CrashSentry — crash forensics + debug toolkit for Brotato mods

Mod id: `dbg-CrashSentry` · tested against Brotato **1.2.0.1** / ModLoader **6.3.0** (Godot 3.7.dev custom build)

## Why the normal logs let you down

I read the decompiled game + ModLoader sources and measured the behaviour:

* `user://logs/godot.log` is always the **current** session. On every launch the engine
  renames the previous one to `godot<date>T<time>.log`, so after a crash the file you
  open first is the *new* session and the crash information sits in the older file.
* Brotato's own crash reporter (`singletons/crash_reporter.gd`) only greps the newest
  rotated engine log for lines containing `mods-unpacked`. When it finds any (which
  happens for plain parse errors, not just crashes) it **disables every mod** for the
  next launch and the mod list in `mod_user_profiles.json` gets rewritten empty.
  That loop is what makes it look like "nothing was logged, mods just vanished".
* Godot's crash handler backtrace goes to *stderr*; when the game is started by Steam
  stderr is not stored anywhere you look at.
* Nothing records **what the game was doing** when it died: scene, wave, run, node
  counts, memory. That is what a post-mortem usually needs.

## What the mod does

Always on, no configuration needed:

| feature | what you get |
|---|---|
| **flight recorder** | `user://logs/sentry/trail.log` — a timestamped trail of scene changes, run state (wave/danger/endless), memory + node counts, frame hitches, every engine error line (with the owning mod named) and every mod log line you push into it. Written from a background thread, so it survives a segfault and keeps running while the tree is paused (shop, upgrade screen). |
| **crash detection** | a `session.marker` file is deleted on a clean shutdown. If the next launch finds it, the previous session died → a full **post-mortem report** is written. |
| **post-mortem report** | `user://logs/sentry/reports/crash-<time>.txt`: previous session marker + last heartbeat (scene/wave/nodes/mem/paused), the last trail entries of that session, freeze markers, the tail of the previous engine log (including the Godot backtrace if there was one), a **"suspects" table** of every mod mentioned in that log with counts, all loaded mods + versions, all installed script extensions, what Brotato's own crash reporter thought, run snapshot, environment, engine log paths. |
| **freeze detector** | if the main loop stops responding for more than `freeze_ms`, the watchdog thread writes `FREEZE` entries to `user://logs/sentry/freeze.log` with the last known state — the only way to tell a hang from a crash after the fact. |
| **engine-log tail** | follows `user://logs/godot.log`, `user://logs/modloader.log` and Brotato's own `user://<profile>/log.txt`, and re-logs every `SCRIPT ERROR` / `ERROR:` / `WARNING:` next to the current scene + wave, tagged `[mods: <mod id>]`. Error storms (>120 errors / 5 s) get their own line. |
| **freed-object watchdog** | `watch(obj, label)` reports when that object disappears and how many live signal connections it had — the classic "previously freed instance" crash. |
| **overlay** | in-game panel with fps, nodes, memory, wave, error counts and the last captured errors, plus the absolute path of your trail file. |

### Hotkeys

| key | action |
|---|---|
| `F8` | toggle the overlay |
| `F9` | write a state dump into `user://logs/sentry/reports/dump-<time>.txt` |
| `F10` | copy diagnostics (state + recent errors + last trail lines + mod list) to the clipboard |
| `F7` | open the reports folder in your file manager |

The game itself uses `F5` (debug menu, debug builds only), `F6` (freeze) and `Insert`
(bug report), so F7-F10 are free.

## Install

```bash
cd ~/Apps/Godot/brotato-mods/CrashSentry
./install.sh              # builds dbg-CrashSentry.zip
./install.sh items        # list your subscribed workshop item folders
./install.sh workshop 3829941160   # drop the build next to an item you already subscribe to
```

Why the workshop folder: the retail Steam build has `steam_workshop_enabled = true`
(feature tag `steam` is compiled into the build, so it is always true). That means the
plain `<game>/mods` folder **and** `--mods-path` are never read, and mods only load when
the Steam API answers `get_subscribed_mods()`. The mod loader does mount *every* `.zip`
inside every subscribed item folder, so dropping your build there is the fastest local
test loop. Caveat: a Steam subscription update can delete the extra file; re-run
`./install.sh workshop <id>` then. For a permanent/shareable install upload it with
`GodotWorkshopUtility.x86_64` (ships next to the game binary).

`./uninstall.sh` removes those copies again.

## Config (in-game Mods → CrashSentry → config, JSON schema)

| key | default | meaning |
|---|---|---|
| `boost_mod_log_level` | true | force ModLoader log level to DEBUG (other mods' `debug` lines land in `modloader.log`) — same as launching with `-vvv` |
| `tail_engine_log` | true | follow the engine / modloader / Brotato log files |
| `watchdog_thread` | true | write the recorder from a thread (needed for freeze detection and crash durability) |
| `freeze_ms` | 3000 | main-loop silence before a FREEZE entry |
| `frame_hitch_ms` | 500 | log a HITCH line when a frame is longer than this (0 = off) |
| `freed_watchdog` | true | poll the objects registered with `watch()` |
| `overlay_enabled` | false | show the overlay from startup |
| `report_errors_in_overlay` | true | show captured error lines in the overlay |
| `alert_on_crash_found` | true | banner at startup when a crash report was written |
| `memory_log_seconds` | 20 | MEM line cadence (0 = off) |
| `keep_mods_enabled` | true | rename an already-blamed rotated log into `logs/sentry/evidence/` (never deletes it) so the game's crash reporter has nothing to blame on the next launch |
| `sanitize_engine_log` | true | overwrite every already-read `mods-unpacked` in the live logs with `mods_unpacked` (same length) so the game's crash reporter never gets blamed evidence in the first place |

## Why your mod list silently gets switched off

Brotato's `singletons/crash_reporter.gd` runs at every startup. Its constant pool
(read straight out of `Brotato.pck` of 1.2.0.1) contains the pattern it uses:

* it picks the newest rotated engine log, i.e. the one whose name matches
  `godot<YYYY-MM-DD>T<HH.MM.SS>.log` (there is an ISO-ish regex in the bytecode),
* it looks for an `ERROR:` line that contains the literal text `mods-unpacked`, **or**
  whose previous line contains it,
* it names that mod and switches mods off for the whole launch
  (`Mods are currently disabled`, `CRASH_RECOVERY_MESSAGE_MODS_DISABLED`).

A mod that merely *fails to compile* produces exactly that shape of output, so one
broken script patch silently empties your mod list for the next launch. Reproduce:

```bash
python3 - <<'EOF'
import os
for fn in sorted(os.listdir('user://logs')):
    p = os.path.join('user://logs', fn)
    prev = ''
    n = 0
    for line in open(p, errors='replace'):
        if 'ERROR:' in line and ('mods-unpacked' in line or 'mods-unpacked' in prev):
            n += 1
        prev = line
    print(fn, n)
EOF
```

CrashSentry fights it in two places, both in `keep_mods_enabled` / `sanitize_engine_log`:

1. **masking (the root fix)** — every occurrence of `mods-unpacked` that the tailer has
   already read is rewritten in place to `mods_unpacked`. Same byte count, so the
   engine's append cursor and the file size stay valid, and the rotation the engine does
   at the next startup produces a log the reporter cannot blame. Nothing is lost: the
   unmasked text (with `[mods: <mod id>]` attribution) is in `trail.log`.
2. **evidence move** — a rotated log that is *already* blamed gets renamed into
   `logs/sentry/evidence/` (one `rename()`, nothing is ever deleted), so the launch
   after it starts with mods enabled.

Masking only touches bytes the tailer has already consumed, so it can never race with
the engine's own write.


## Startup step breadcrumbs (`csentry step:`)

Every step of the startup path prints a `csentry step: <what>` line to stdout (and
therefore into Steam's `console-linux.txt`) *before* it runs. When the game dies
without any output, the last breadcrumb in `user://logs/godot.log` is the line it died
on:

```bash
grep "csentry step" ~/.local/share/Brotato/logs/godot.log | tail
grep "csentry step" ~/.local/share/Steam/logs/console-linux.txt | tail
```

Those breadcrumbs are what tells a startup crash inside this mod (1.2.1 shipped without
them) apart from a startup crash somewhere else.


## Calling it from another mod

The mod main node lives at `/root/ModLoader/dbg-CrashSentry`:

```gdscript
var sentry = get_node_or_null("/root/ModLoader/dbg-CrashSentry")
if sentry:
	sentry.trail("wave manager built, %s groups" % groups.size(), "NCL")
	sentry.watch(effect_node, "my buff effect")   # logs when it dies
	var r = sentry.safe_call(other_node, "refresh", [], "my tooltip")   # {"ok":, "error":, "value":}
	if not r.ok:
		sentry.trail("refresh failed: " + str(r.error), "ERROR")
	sentry.dump_state("before applying my patch")
	sentry.set_overlay_visible(true)
```

`safe_call` is the closest thing Godot 3 has to try/catch: it refuses null/freed
targets (instead of letting the engine segfault on them), writes the call to the trail
first, and returns `{ok, error, value}`.

## Reading a crash report, in practice

1. `cat ~/.local/share/Brotato/logs/sentry/reports/crash-*.txt` (that is `user://logs/…`).
2. Look at **last heartbeat** — that is the last state that existed.
3. Look at the **last flight-recorder entries** — the phase trail before death.
4. Look at **suspects** — the mods whose files appear in the error lines of that run.
5. If `freeze markers` is not empty, it hung before it died (usually a runaway loop in
   some `_process`, look at HITCH lines).

To also catch Godot's native backtrace for hard crashes, launch once with:

```
%command% 2>>/tmp/brotato_stderr.log -vvv
```

## Notes / limits

* Godot 3 has no runtime hook for script errors, so errors are recovered by *tailing*
  the engine log file rather than by intercepting them — which is also why they carry a
  timestamp of when CrashSentry read them, not when the engine printed them.
* The engine log is written by Brotato itself; a SIGKILL in the middle of a line can
  leave a torn last line (the report shows it as-is).
* Everything is defensive: no script extensions, no scene patches, no global class
  registration — if you disable the mod, the only leftover is its log folder.
* Verified offline (Godot 3.7-dev1, headless harness with stub `ModLoaderStore` /
  `ModLoaderLog` autoloads, the mod's real `mod_main.gd` instantiated in a real scene
  tree, seeded with copies of the real `user://logs`): a 226 KB storm log with 273
  `mods-unpacked` occurrences gets fully masked (`mods_unpacked`, file size and line
  count unchanged, blame count 52 -> 0), an already-blamed rotated log gets renamed
  into `logs/sentry/evidence/`, a `clean: false` marker produces a full post-mortem
  report, `OS.crash()` mid-frame leaves the trail + marker, a 9 s main-loop freeze
  produced 12 FREEZE entries, freed-object watch, safe_call, report/dump writing,
  clipboard copy and the manifest config schema (validated with the game's own
  JSON-Schema validator) all pass.
