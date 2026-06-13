---
name: browser-form-automation
description: Drive authenticated web-console and browser forms through semantic controls, Playwright/DOM locators, or form APIs instead of repeated coordinate clicks and blind keystrokes. Use when filling or editing forms in Chrome or the in-app browser, especially admin consoles, OAuth/client settings, secret managers, or pages where focus or typing is failing. Not for read-only page inspection or a single obvious click.
---

# Browser Form Automation

## Use When

- The user asks you to configure or verify an authenticated web console, admin page, or form.
- You are editing origins, redirect URIs, secrets, settings, or multi-field config in Chrome, Browser, or another browser automation surface.
- A click/type attempt misses focus, typing lands nowhere, `cmd+a` selects the page, a console or side panel steals focus, or coordinates have changed after scrolling.

Near misses:

- Read-only inspection or screenshots: use the Browser/Chrome skill directly.
- A single visible button/link with no text entry: a coordinate or vision click is fine, then check state.
- A provider API or secret-retrieval task: use `local-secret-retrieval` first; use this skill only when you must operate the web UI.

## Procedure

1. Start with the relevant Browser/Chrome skill and its runtime docs. Prefer the browser's semantic API: Playwright locators, accessible labels, `form_input`, or JavaScript DOM writes with dispatched `input`/`change` events.
2. Map the form before changing it: list visible inputs/buttons with labels, placeholders, current values, disabled state, and the current URL/account/project. Confirm it is the expected account/project before writing.
3. Use coordinates only to expose or open a control. Do not use stale x/y clicks as the main data-entry method for text fields.
4. After any missed-focus signal, stop coordinate typing immediately. Switch to locator/DOM entry before retrying. A second blind click/type sequence without new DOM evidence is the failure pattern.
5. When using DOM writes, mimic user input enough for frameworks: set the value through the native setter when needed, dispatch `input` and `change`, then read the field value back.
6. Verify the result from the page's own state before saving/submitting: current input values, selected options, validation messages, success toast, or saved detail page.
7. If saving transmits secrets, credentials, or external state and the user's request did not already authorize that exact destination/action, follow browser safety confirmation. Otherwise finish the authorized flow.

## Gotchas

- Screenshots prove what is visible, not which element has focus.
- Clipboard paste plus `cmd+a` is brittle on web consoles; if `cmd+a` selects the whole page, the input never had focus.
- Opening multiple tabs rarely parallelizes one browser-extension session; finish one form deterministically unless separate browser sessions are actually available.
- Google Cloud Console and similar SPAs often keep hidden inputs and custom components; labels and DOM state beat pixel positions.

## Verification

- Positive: "drive Google Cloud Console and Infisical to set OAuth redirect URIs/secrets" -> map fields by DOM, set values by locator/form/JS, read them back, then save.
- Positive: "my browser form typing is not sticking" -> stop coordinate typing and inspect DOM/focus before retrying.
- Near miss: "screenshot this page" -> browser/chrome only.
- Near miss: "fetch Sentry issues with an auth token" -> `local-secret-retrieval`.

## Sources

- Trigger transcript: `/Users/advaitpaliwal/.claude/projects/-Users-advaitpaliwal-Companion-Code-companion/361d51b1-3306-410b-8019-39c5d7d0814e.jsonl:236` records the agent identifying the root failure: coordinate clicks were not landing in fields, `cmd+a` selected the whole page, and the console was stealing focus.
- Same transcript: `/Users/advaitpaliwal/.claude/projects/-Users-advaitpaliwal-Companion-Code-companion/361d51b1-3306-410b-8019-39c5d7d0814e.jsonl:239` and `:240` show the corrected move: map the DOM inputs/buttons and drive the form precisely.
- Chrome skill reference: `/Users/advaitpaliwal/.codex/plugins/cache/openai-bundled/chrome/26.609.41114/skills/control-chrome/SKILL.md:69` says to collect a fresh DOM snapshot when locator ground truth is needed, and `:75` allows node/Playwright clicks when the best UI element is unclear.
- Browser skill reference: `/Users/advaitpaliwal/.codex/plugins/cache/openai-bundled/browser/26.609.41114/skills/control-in-app-browser/SKILL.md:57` gives the same DOM-snapshot guidance after interactions.
