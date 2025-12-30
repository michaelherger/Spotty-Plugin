# TASK — Continue work on LMS (saved chat context)

Summary
- Saved conversation context so you can SSH into the LMS server and continue the task.
- LMS installation root (reported): `/usr/share`.
- Key files to inspect locally before deploying: `spotty-fork/API/RateLimit.pm`, `spotty-fork/API/API.pm`.

Planned steps
1. Inspect and prepare changes locally (edit `RateLimit.pm` and `API.pm`).
2. Run Perl tests locally: `prove -v t/01-rate-limit.t`.
3. Transfer plugin to LMS and install under the plugin directory found in `/usr/share`.
4. Restart LMS and verify behavior and logs.

Quick checks (on remote)
```bash
# find likely plugin directories under /usr/share
sudo find /usr/share -type d -iname Plugins -maxdepth 4 2>/dev/null
sudo find /usr/share -type d -iname "*Plugin*" -maxdepth 4 2>/dev/null
```

Copying/deploying the plugin
Option A — push from local (recommended when you keep this chat open locally):
```bash
# from your local machine in the repo root
scp -r spotty-fork username@lms-host:/tmp/spotty-fork
# then on the remote
sudo mv /tmp/spotty-fork /usr/share/<PLUGINS_DIR>/spotty
sudo chown -R squeezebox:squeezebox /usr/share/<PLUGINS_DIR>/spotty
sudo systemctl restart logitechmediaserver
```

Option B — pull on the remote (if remote has network access & git):
```bash
# on the remote
cd /usr/share/<PLUGINS_DIR>
sudo git clone https://github.com/yourusername/Spotty-Plugin.git spotty
sudo chown -R squeezebox:squeezebox spotty
sudo systemctl restart logitechmediaserver
```

Logs and verification
```bash
# follow LMS logs
sudo journalctl -u logitechmediaserver -f
# or if server.log exists
tail -f /var/log/squeezeboxserver/server.log
```

Local testing commands
```bash
# run perl tests (from repo root)
prove -v t/01-rate-limit.t
```

Notes
- Replace `username`, `lms-host`, and `<PLUGINS_DIR>` with the actual values found on the remote.
- If you want, I can commit this `TASK.md` and prepare the edits to `RateLimit.pm` now.

If you SSH to the LMS and want me to continue from there, either:
- keep this chat open locally and run the commands in a separate terminal, or
- copy `TASK.md` into the remote and open a new chat session that references this file (I can pick up from it).

---

Remote copy (quick)

Copy this file to the LMS so the same instructions are available on the server.

Example (replace placeholders):

```bash
# from your local machine (repo root)
scp TASK.md username@lms-host:/tmp/TASK.md

# on the LMS (after SSHing in)
sudo mv /tmp/TASK.md /usr/share/<PLUGINS_DIR>/spotty/TASK.md
sudo chown root:root /usr/share/<PLUGINS_DIR>/spotty/TASK.md
```

Notes:
- Replace `username`, `lms-host`, and `<PLUGINS_DIR>` with the actual values on your system.
- If the LMS plugins live elsewhere under `/usr/share`, move the file accordingly.

Quick remote commands to install the plugin copy (if you SCP'ed the full `spotty-fork` directory):

```bash
# on the LMS
sudo mv /tmp/spotty-fork /usr/share/<PLUGINS_DIR>/spotty
sudo chown -R squeezebox:squeezebox /usr/share/<PLUGINS_DIR>/spotty
sudo systemctl restart logitechmediaserver
sudo journalctl -u logitechmediaserver -f
```

If you'd like, I can also create a minimal `README_REMOTE.md` instead—tell me which you prefer.
