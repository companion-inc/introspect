---
name: obsidian-vault-handoff
description: Register a folder as an Obsidian vault before handing off `obsidian://open` links on macOS, so the user actually opens what you generated instead of hitting "Unable to find a vault for the URL".
---

# Obsidian vault handoff

## Problem

You generated markdown into a folder and sent the user an `obsidian://open?vault=...` or `obsidian://open?path=...` URL. Obsidian rejected it with "Unable to find a vault for the URL" even though the folder has a `.obsidian/` directory.

Obsidian's URL handler resolves vault names and paths only against its app-level registry at `~/Library/Application Support/obsidian/obsidian.json`. A `.obsidian/` directory inside the folder is not enough — the folder must be registered.

## When to load

- About to send the user an `obsidian://open?...` URI for a folder you created or moved.
- The user reports "Unable to find a vault for the URL".
- You wrote markdown intended to be opened in Obsidian (`.obsidian/`, wiki-links, MOC/START-HERE pages) into a path that isn't yet a known vault.

Do not load for: editing files already inside a folder that is registered in Obsidian's vault registry — those URIs already work.

## Procedure

1. Read the current registry:
   ```bash
   cat "$HOME/Library/Application Support/obsidian/obsidian.json"
   ```
   Confirm whether the target absolute path appears under `vaults.<id>.path`. If it does, skip to step 4.

2. If Obsidian is running, quit it first — a live Obsidian process rewrites `obsidian.json` on exit and will clobber your edit:
   ```bash
   osascript -e 'tell application "Obsidian" to quit'
   ```

3. Add a vault entry. The key is a random 16-hex id (Obsidian's convention), not a slug. Use a real epoch-ms timestamp. Preserve the existing entries.
   ```bash
   python3 - <<'PY'
   import json, os, secrets, time, pathlib
   p = pathlib.Path.home() / "Library/Application Support/obsidian/obsidian.json"
   data = json.loads(p.read_text())
   vault_path = "/absolute/path/to/folder"
   if not any(v["path"] == vault_path for v in data["vaults"].values()):
       vid = secrets.token_hex(8)
       data["vaults"][vid] = {"path": vault_path, "ts": int(time.time() * 1000), "open": True}
       p.write_text(json.dumps(data))
   PY
   ```

4. Open the URI by vault name (the basename of the path), not by `path=`. `vault=` is more reliable across Obsidian versions:
   ```bash
   open "obsidian://open?vault=$(basename "$VAULT_PATH")&file=00-START-HERE"
   ```

5. Verify before claiming the handoff worked:
   - Re-read `obsidian.json` and confirm the path is listed.
   - Wait a beat and check Obsidian is the frontmost app:
     ```bash
     osascript -e 'tell application "System Events" to name of first application process whose frontmost is true'
     ```
   - If Obsidian is not frontmost or the URI returned an error toast, report that, not success.

## Gotchas

- A `.obsidian/` folder alone is not registration. Obsidian creates it on first open; pre-creating it does not register the vault.
- Slug keys like `"ai-for-normies"` work but pollute the registry — keep ids 16-hex. Duplicate entries for the same path are harmless but ugly; dedupe in step 3.
- `obsidian://open?path=<abs-md-file>` resolves only if that file lives inside a registered vault. If it fails, register the parent vault first, then retry.
- macOS spotlight-style "scoped folder" paths work the same as `~/Projects/...`; there is nothing special about where the folder was created.

## Verification

Done means:
- `obsidian.json` contains the vault path.
- A second `open obsidian://open?vault=...&file=...` succeeds and Obsidian is frontmost.
- Then, and only then, hand the URL back to the user.

## Sources

- Obsidian URI scheme docs: https://help.obsidian.md/Concepts/Obsidian+URI
- Observed registry format on this machine: `~/Library/Application Support/obsidian/obsidian.json` (16-hex id keys, `path`/`ts`/`open` fields).
- Internal failure pattern: an agent sent an `obsidian://open?path=...` link for a generated folder before registering that folder in `obsidian.json`, and Obsidian rejected the URL.
