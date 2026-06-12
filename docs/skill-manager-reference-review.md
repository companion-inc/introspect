# Skill Manager Reference Review

Understanding score: 82/100. I checked the public repos and screenshots. `asm` has source code; `Skills-Manager` currently exposes product docs/screenshots but not its Tauri/React source.

## Sources Checked

- `https://github.com/jiweiyeah/Skills-Manager`
- `https://github.com/luongnv89/asm`
- `https://github.com/BerriAI/self-improving-agent`
- Local clones under `/tmp/introspect-skill-research/`

## Useful Product Patterns

- Skills need an inventory surface, not a path list. `asm` models name, version, description, creator, license, compatibility, allowed tools, provider, scope, symlink target, real path, token count, warnings, eval summary, disabled state, and duplicate groups.
- The main view should expose counts first: total skills, global/project split, tools/providers, symlinks, duplicates, and current filter/search.
- The inspect view should answer "what is this and where does it load?" before showing raw text. Show scope, provider, path, symlink target, frontmatter, file count, token estimate, warnings, and then contents.
- Provider-aware scanning beats recursive home-folder scanning. `asm` has explicit provider configs for Claude, Codex, Hermes, Agents, Cursor, Windsurf, Cline, Roo, Continue, Copilot, Aider, OpenCode, Zed, Augment, Amp, Gemini, Antigravity, and Pi.
- Duplicate audit is a first-class workflow. `asm` groups duplicates by directory name and frontmatter name, then recommends which instance to keep.
- Marketplace/catalog browsing is separate from local inspection. Introspect should not mix "what is installed and loaded" with "what can I install" in the same pane.
- `Skills-Manager` shows the right desktop shape for non-terminal users: left nav, Skills, Tools, Marketplace, Settings, Feedback, search, cards, per-tool enablement chips, and symlink sync.
- `self-improving-agent` is relevant for write safety, not skill browsing: it uses two tools, writes one minimal proposal, requires explicit approval, then applies through a branch/PR path.

## Introspect Decisions

- Keep Projects as a hierarchy/detail browser: roots -> agent files -> skills -> file preview.
- Default to the current repo first, then global Claude/Codex/Agents, then broader project roots.
- Paint priority roots before the full broad scan so the app is usable immediately.
- Add duplicate/audit signals before adding install/marketplace features.
- Keep autonomous self-improvement behind a proposal/staging model. Do not silently apply multi-file prompt/skill edits once the app has a UI for pending changes.
- Later: add a Tools/Providers view with enable/disable toggles and paths, then a separate Marketplace view if public skill installation becomes part of the product.
