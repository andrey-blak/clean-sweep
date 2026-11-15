# clean-sweep

Removes scratch dirs (e.g. .claude, .hermes, .cc-writes) on a schedule. 
Age guard defaults to 24h. 

## Install

### systemd user timer

(preferred)
```bash
mkdir -p ~/.local/bin ~/.config/clean-sweep ~/.config/systemd/user
install -m 755 clean-sweep ~/.local/bin/clean-sweep
install -m 644 config.ini ~/.config/clean-sweep/config.ini
install -m 644 install-systemd/clean-sweep.service install-systemd/clean-sweep.timer ~/.config/systemd/user/
systemctl --user daemon-reload
~/.local/bin/clean-sweep -n                 # dry run first — review output
systemctl --user enable --now clean-sweep.timer
systemctl --user list-timers | grep clean-sweep
journalctl --user -u clean-sweep -n 50      # what it deleted
```

Persistent=true catches up after sleep/shutdown. Runs while logged in; for logged-out operation: loginctl enable-linger $USER. 

Installation files:
```
clean-sweep            -> ~/.local/bin/clean-sweep          (chmod 755)
config.ini             -> ~/.config/clean-sweep/config.ini
clean-sweep.service    -> ~/.config/systemd/user/
clean-sweep.timer      -> ~/.config/systemd/user/
```

#### Disable systemd

disable, keep files:
```bash
systemctl --user disable --now clean-sweep.timer
```

#### Uninstall systemd

Full removal:
```bash
systemctl --user disable --now clean-sweep.timer
rm ~/.config/systemd/user/clean-sweep.{service,timer}
systemctl --user daemon-reload
rm ~/.local/bin/clean-sweep ~/.config/clean-sweep/config.ini
```

### Cron

(fallback instead of systemd — do NOT run both)
```bash
command -v crontab || sudo apt install cron
mkdir -p ~/.local/bin
install -m 755 clean-sweep ~/.local/bin/clean-sweep
mkdir -p ~/.local/state
crontab -e
# add:
0 * * * * flock -n /tmp/clean-sweep.lock $HOME/.local/bin/clean-sweep >> $HOME/.local/state/clean-sweep.log 2>&1
```

#### Disable

comment the line out, or: 
`crontab -l | grep -v clean-sweep | crontab -`

#### Uninstall
Uninstall: remove the line, then delete script/config as above.
Cron misses runs while the machine is off/asleep; no journal — check the log file.

## Config quick reference
```
[scan]  
        roots (comma list, all scanned; quote entries containing commas;
        $HOME, ${VAR:-default}, ~ and ~user expanded; roots canonicalized,
        symlinked roots work, duplicates deduped, / refused),
        skip (never descend), 
        min_age_hours (default 24, max 876000), 
        dry_run (default false; CLI -n/--dry-run wins)
[targets]  
        key = name | relative/path | absolute path; 
        value = mode[, age_hours]
        mode: empty (recursively-empty only) | force (with contents — use for scratch only)
        bare name matches anywhere; relative path = suffix match (.claude/.cc-writes only inside .claude); absolute = exact location;
        most specific match wins. 
        Quote keys with edge spaces: " foo " = empty
```

## Behavior & safety

- Expansion is single-pass: variable values are inserted verbatim and never re-scanned (self-referential vars cannot loop). `:-` defaults expand one level, so `${X:-$HOME/d}` works. Unknown `~user` is a fatal config error.
- Roots and absolute targets are canonicalized (`realpath`), so `..` and symlinks cannot disguise a path. `/` and `$HOME` are additionally protected by device:inode identity, not just spelling.
- Empty mode uses `rmdir` — atomic: a directory that gains contents between scan and deletion is never removed. Before any deletion the path's identity is re-checked; a path replaced since the scan is skipped and logged.
- Dry-run simulates cascading deletion: a parent is previewed when all its entries would be removed. Preview matches what a real run would delete.
- Scan errors are not hidden: inaccessible directories or failed scans are logged per root, other roots still get cleaned, and the run exits 1.
- Age guard uses scan-time mtimes; dirs with future mtimes are always skipped.
