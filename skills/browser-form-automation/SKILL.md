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

- Internal failure pattern: coordinate clicks missed form fields, `cmd+a` selected the page, and console focus stole typing; mapping DOM inputs/buttons fixed the flow.
- Chrome and browser automation skill references: collect a fresh DOM snapshot when locator ground truth is needed, and use browser/Playwright-level interactions when the visible UI element is ambiguous.
