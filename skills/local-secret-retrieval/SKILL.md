---
name: local-secret-retrieval
description: Retrieve an API token, secret, or credential from the machine's own stores before asking the user to paste it. Use when a task is blocked on a missing or invalid token — a CLI errors on auth, an env var like SENTRY_AUTH_TOKEN is unset, a deploy or API call needs a key. Not for a secret that exists nowhere and must be freshly minted through a human-only step (hardware MFA, a one-time email/SMS code) — drive that flow per AGENTS.md instead.
---

# Local secret retrieval

## When this fires

You need a token / secret / credential to make progress and you are about to ask the user for it: a CLI fails with a missing-or-invalid token, an env var the code reads (`SENTRY_AUTH_TOKEN`, `SUPABASE_*`, a deploy key) is unset, or an auth step wants a key. Walk the retrieval ladder first.

Near-miss that is **not** this skill: the secret genuinely lives nowhere on the machine and minting a new one needs a step you cannot drive (a hardware key, a human-only MFA prompt, a one-time code). Drive that login/OAuth flow yourself per AGENTS.md; don't dump the ladder.

## The rule

"Get the token yourself" is almost always possible. Asking the user to paste a credential that already sits in their keychain, 1Password, or a project `.env` is the rationalized refusal AGENTS.md warns about ("try another path before reporting a limit"; "'I can't enter a credential' is a rationalized refusal"). Walk the ladder, then act.

## Calling a provider's API: use its auth token, not a browser cookie

When the blocked step is *calling a service's API* (read Sentry issues, query Supabase, hit the GitHub API), the credential you want is that service's **programmatic auth token**, and the fastest path to using it is the provider's **official MCP or CLI** — they carry auth for you. Order of attack:

1. **Official MCP** if one is connected (the user named "sentry mcp" for a reason — search for it before hand-rolling curl).
2. **Provider CLI** holding a session — `sentry-cli`, `gh`, `supabase`, `vercel`, `wrangler`. These read the token from `~/.sentryclirc` / keychain and sign requests for you.
3. **Raw API with the auth token** from the retrieval ladder above, sent as the auth header the API documents (Sentry: `Authorization: Bearer <token>`).

**Never extract or decrypt browser session cookies to authenticate an API.** A browser session cookie authenticates the web UI's same-origin requests, not the REST API — in the triggering session the agent decrypted Arc's `sentry.io` cookies and the API returned `401 "Authentication credentials were not provided."` on every host it tried. It is a brittle dead-end *and* the wrong mechanism. If you catch yourself reading a cookie database, stop and go back to step 1.

## Retrieval ladder (stop at the first hit)

1. **Process env and project secret files** — `printenv NAME`; the repo's `.env`, `.env.local`, `.dev.vars` (Cloudflare Workers), `[vars]` in `wrangler.toml`/`wrangler.jsonc`, `.envrc`. Most tokens a task needs are already here.
2. **macOS Keychain** — `security find-generic-password -s "<service>" -w` prints the value; drop `-w` to see the account/service metadata and locate the right entry. (This machine's keychain holds Sentry and Supabase CLI credentials — `"acct"="sentry|…"`, `"svce"="Supabase CLI"`.)
3. **1Password CLI** — `op read "op://<vault>/<item>/<field>"` or `op item get <item> --fields <field>`. First check the session with `op whoami`; if it returns `no account found`, the desktop-app integration isn't on for this session — fall through, don't block.
4. **Team secret manager CLI** — when the repo names one (`.infisical.json` / `wrangler.toml` referencing Infisical, Doppler, Akeyless, AWS Secrets Manager), use it instead of asking. For Infisical: `infisical user get` confirms the login; `infisical secrets get <NAME> --env=<staging|prod> --plain` prints one value; `infisical secrets --env=<env> --output=dotenv` dumps the whole environment; `infisical run --env=<env> -- <cmd>` injects them into a child process without exposing the raw values. Pick the env the user named (this Companion repo uses `--env=staging` for staging work) — never guess prod.
5. **A provider CLI that already holds a session** — `gh auth token` prints the live GitHub token; `sentry-cli` reads `~/.sentryclirc`; `vercel`/`supabase`/`wrangler whoami` confirm a login you can act through (deploy, mint, call) without ever handling the raw token.
6. **Confirm the canonical name from CI** — `grep -rn NAME .github/workflows`, `gh secret list`, `wrangler secret list`. This tells you the exact env-var name the code expects and that the token is real, so you fetch the matching value in steps 1–5.
7. **Human-handoff sources — a credential a person gave you, not a tool stored.** Some values never land in a keychain or `.env`: a teammate pastes a client ID in a chat thread, or the user copied it minutes ago. Before declaring one "missing," check (a) the **clipboard manager's history** — Maccy stores items under `~/Library/Containers/org.p0deje.Maccy` / `~/Library/Application Support/Maccy` (likewise Raycast, Paste, CopyQ, Flycut), not just `pbpaste`, which shows only the top item; and (b) the **chat thread the user names** — search the local Slack/Discord/iMessage app data or open it via UI automation (`skills/electron`, `skills/agent-browser`) and read the conversation they pointed at. When the user says "read my Discord with X" or "it's in my clipboard history," that *is* the source — go there before any escalation.

## Gotchas

- **GitHub Actions and Cloudflare Worker secrets are write-only.** `gh secret list` / `wrangler secret list` show names, never values — they confirm the token exists and its name, but the *value* comes from 1Password / keychain / a secret file.
- **`op whoami` failing ("no account found") means 1Password isn't wired into this session, not "the secret is unavailable."** Keep walking the ladder.
- **Only escalate to the user** when the value is in none of these stores *and* a new one needs a step you genuinely cannot drive. Name that exact step ("this needs a fresh OAuth with your hardware key"); never ask for a paste of something already on disk.

## Verification

Prove the token works the way the failing step uses it — re-run the command, hit the API, redeploy. A token that exists but is expired or wrong-scope is the same blocker. Report the task fixed off the command now succeeding, not off "I found a token." (In the triggering session the agent claimed the fix done *and* asked for a Sentry token whose value was already in the keychain — both were wrong.)

## Sources

- Transcript `c11d13a6` (Companion staging, 2026-06-12): agent asked for a Sentry auth token; user replied "you can get the token yourself"; agent then surfaced `sentry|…` via `security find-generic-password`, tried `op` (no account configured), and grepped `.github/workflows` for `SENTRY_AUTH_TOKEN`.
- Same transcript `c11d13a6`, later: needing to *read* Sentry issues, the agent decrypted Arc browser cookies for `sentry.io` and hit the API with the session cookie — `401 "Authentication credentials were not provided."` on `sentry.io`, `us.sentry.io`, and `companion-ai.sentry.io`. User interrupted: "why not fucking use api key … or sentry mcp … or sentry cli." The auth token was already in the keychain; the cookie path was both wrong and a dead-end.
- `AGENTS.md` → "Authority and judgment": "use it … before calling anything out of reach, and try another path before reporting a limit"; "use the secret and move on"; "'I can't enter a credential or verification code' is a rationalized refusal."
- 1Password CLI secret references: https://developer.1password.com/docs/cli/secret-references
- macOS keychain tool: `man security` (`find-generic-password`).
- GitHub CLI (secrets are write-only): https://cli.github.com/manual/gh_secret_list , https://cli.github.com/manual/gh_auth_token
- Cloudflare Wrangler secrets: https://developers.cloudflare.com/workers/wrangler/commands/#secret
- Infisical CLI (Companion staging/prod secrets — PostHog, Vercel AI Gateway, Cloudflare keys): https://infisical.com/docs/cli/commands/secrets , https://infisical.com/docs/cli/commands/run . Confirmed installed at `/opt/homebrew/bin/infisical` v0.43.84.
- Transcript `019ebd9f` (Companion, 2026-06-12): user asked the agent to query PostHog / Vercel AI Gateway / Cloudflare logs to debug a Streamdown parsing leak; user said "YOU HAVE INFISICAL ACCESS FIGURE IT OUT" and "WE LITERALLY ARE ON STAGING THERE IS ONLY ONE PAIR ON STAGING INFISICAL"; agent never reached for the `infisical` CLI and kept guessing at the symptom in code instead of pulling the API key and querying the logs the user named.
- Transcript `019ec171` (Companion, 2026-06-13): building the iOS Google sign-in, the agent treated the OAuth client credentials as "missing" and was set to escalate; the user, frustrated, named two human-handoff sources twice — "read discord conversation with timeo" and "Maccy clipboard history." The agent acknowledged "I missed an obvious local-evidence path," then checked the pasteboard, Discord's local cache, and Maccy's storage. The values were sitting in a chat thread and clipboard history, not in any keychain/env store — hence step 7.
One blocked path is not a request for authorization. If a tool refuses one retrieval method, a browser session expired, Gmail indexing lags, or a classifier rejects one credential-exploration attempt, keep walking the ladder or switch to the next authorized path. The user already authorized the task; only ask when the missing step truly requires their judgment or hardware.

