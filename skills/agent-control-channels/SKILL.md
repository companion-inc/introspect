---
name: agent-control-channels
description: How an LLM agent should emit a structured decision — a mode flag, a control action, a state change — back to its host system. Use when building or debugging an agentic product where the model has to signal something (quiet/silent run, archive, hand-off, "done", a routing choice), when a marker or tag is leaking into the visible transcript, or when the host is regex-scraping the model's prose to recover intent. Grounded in how models actually emit tokens.
---

# Agent control channels

## The one rule

When the model must signal a structured decision to the host, that signal is a **tool call** — the native structured channel — not a marker the model types into its reply.

A typed marker (an XML-ish tag, a sentinel string, `<<QUIET_RUN>>`, a magic word) fails three ways at once:

- **It leaks.** Anything the model types into its reply is part of the reply. It streams to the user verbatim. "Why is it leaking?" is the symptom; the typed marker is the cause.
- **It's emitted unreliably.** The model stutters it, half-types it, rewords it, or wraps it in prose — because it's just more text being sampled, with no schema holding its shape.
- **It forces brittle recovery.** The host now regex-scrapes the prose to recover intent (`extractXFromParts`). That parser is permanently chasing the model's phrasing.

A tool call has none of these: it's a separate structured field, schema-validated, never rendered into the user-facing transcript, and reliably shaped because the API constrains it. The model invoking `archive()` cannot accidentally show the user the word "archive."

## This is the output mirror of an input rule

The global prompt already says: *never infer meaning from natural-language input with regex/heuristics — hard constraints belong at the execution boundary.* Same principle, other direction. Input: don't parse NL to decide what the user meant. Output: don't make the model emit NL for the host to parse to decide what the model meant. Both sides of the model boundary want a typed channel, not prose-scraping.

## How to spot the smell before it ships

You are about to build a typed marker any time you write:

- a prompt instruction telling the model to "include `<tag>`" / "end your reply with X" / "type DONE when finished"
- a host-side function named `extract*FromParts`, `parse*FromText`, `stripMarkersFrom*`, or a regex over `message.content` / `response.text`
- a "mode" the model turns on by saying a special phrase

All three mean the control signal is riding in the prose. Move it to a tool.

## Designing the tool well

- **Name the tool for the user-visible action, one tool per action.** `archive()`, `scheduleFollowup()`, `handOff(agent)`. If the user expects "archive," the tool is `archive` — don't fold it into a generic `quiet_run` the model has to know maps to archiving. A surprising tool name is the next "why the fuck is it calling X instead of Y."
- **Put the mode in a parameter, not a separate code path,** when one action has a quiet/loud variant: `reply({ silent: true })` beats a parallel `quietReply`. One tool the model already knows, one flag.
- **Make the schema do the constraining.** Enum the choices, require the fields. The model can't emit a malformed call the way it can emit malformed prose.
- **Keep the side effect at the boundary, not in the model.** The tool *handler* archives / schedules / suppresses output. The model only decides; the host enforces. Don't trust the model to also remember to not-render something — make not-rendering a property of the channel.

## When a marker is genuinely unavoidable

Rare, but: some surfaces have no tool channel (a raw completion endpoint, a templating layer, a model you don't control). Then:

- Use a delimiter the model will not emit conversationally and strip it server-side *before* anything renders — never after the user has seen it.
- Treat the parser as a known liability, log every parse miss, and rip it out the moment a tool channel exists.
- Don't teach the marker by stuffing instructions into the user turn / chat bubble — that's another leak and it conditions the model to echo it. Put it in the system prompt.

## Method when one is already leaking

Don't patch the regex to catch the latest phrasing — that's re-fighting the symptom. Trace it: the tag is in the reply because the design put it there. The fix is to delete the tag-and-parser pair and register the tool, then remove the now-dead extraction path (no back-compat marker handling left behind). Verify by driving the real flow and confirming the transcript is clean and the action still fires — a passing unit test on the parser proves nothing once the parser is meant to be gone.
