---
name: agent-control-channels
description: How an LLM agent should emit a structured decision or host-consumed payload — a mode flag, control action, state change, routing choice, or UI data envelope — back to its host system. Use when building or debugging an agentic product where the host asks the model to return only JSON, signal quiet/silent/archive/done/hand-off state, choose an app action, feed a menu, or when markers/tags leak into the transcript or host code regex-scrapes prose.
---

# Agent control channels

## The one rule

When the model must signal a structured decision to the host, that signal goes through a **native structured channel** — a tool call for actions/control, or a strict structured response schema for pure data that the app will render. It is not a marker or prompt-only JSON object the model types into its reply.

A typed marker (an XML-ish tag, a sentinel string, `<<QUIET_RUN>>`, a magic word) fails three ways at once:

- **It leaks.** Anything the model types into its reply is part of the reply. It streams to the user verbatim. "Why is it leaking?" is the symptom; the typed marker is the cause.
- **It's emitted unreliably.** The model stutters it, half-types it, rewords it, or wraps it in prose — because it's just more text being sampled, with no schema holding its shape.
- **It forces brittle recovery.** The host now regex-scrapes the prose to recover intent (`extractXFromParts`). That parser is permanently chasing the model's phrasing.

A tool call has none of these: it's a separate structured field, schema-validated, never rendered into the user-facing transcript, and reliably shaped because the API constrains it. The model invoking `archive()` cannot accidentally show the user the word "archive."

## Prompt-only JSON is the same smell

`Return only JSON` is not a control channel. It is prose with braces. It is acceptable only as a fallback when the provider or runtime truly lacks tool calls and structured outputs.

For a menu, routing choice, suggested action list, app mode, or other host-consumed payload:

- use a tool/function call when the model is choosing an app action, changing state, invoking code, or handing the host a command;
- use a strict structured response schema when the model is only returning data that will be rendered, such as a UI card, menu, or explanation parts;
- keep the host parser as schema validation, not recovery from a natural-language prompt contract.

Do not ship a prompt that says "return only JSON" while the host `JSONDecoder`s or `JSON.parse`s the assistant text when the runtime supports one of those native channels.

## This is the output mirror of an input rule

The global prompt already says: *never infer meaning from natural-language input with regex/heuristics — hard constraints belong at the execution boundary.* Same principle, other direction. Input: don't parse NL to decide what the user meant. Output: don't make the model emit NL for the host to parse to decide what the model meant. Both sides of the model boundary want a typed channel, not prose-scraping.

## How to spot the smell before it ships

You are about to build a typed marker any time you write:

- a prompt instruction telling the model to "include `<tag>`" / "end your reply with X" / "type DONE when finished"
- a prompt instruction telling the model to "Return only JSON" for a payload the host consumes
- a host-side function named `extract*FromParts`, `parse*FromText`, `stripMarkersFrom*`, or a regex over `message.content` / `response.text`
- a host-side `JSONDecoder` / `JSON.parse` over assistant text with prompt wording as the only schema enforcement
- a "mode" the model turns on by saying a special phrase

All three mean the control signal is riding in the prose. Move it to a tool.

## Designing the tool well

- **Name the tool for the user-visible action, one tool per action.** `archive()`, `scheduleFollowup()`, `handOff(agent)`. If the user expects "archive," the tool is `archive` — don't fold it into a generic `quiet_run` the model has to know maps to archiving. A surprising tool name is the next "why the fuck is it calling X instead of Y."
- **Put the mode in a parameter, not a separate code path,** when one action has a quiet/loud variant: `reply({ silent: true })` beats a parallel `quietReply`. One tool the model already knows, one flag.
- **Make the schema do the constraining.** Enum the choices, require the fields. The model can't emit a malformed call the way it can emit malformed prose.
- **For data-only UI payloads, use the provider's strict response schema.** A recommendation menu that only returns `message` and `options` does not need a side-effecting tool, but it still needs an API-level schema rather than prompt-only JSON.
- **Keep the side effect at the boundary, not in the model.** The tool *handler* archives / schedules / suppresses output. The model only decides; the host enforces. Don't trust the model to also remember to not-render something — make not-rendering a property of the channel.

## When a marker is genuinely unavoidable

Rare, but: some surfaces have no tool or structured-output channel (a raw completion endpoint, a templating layer, a model you don't control). Then:

- Use a delimiter the model will not emit conversationally and strip it server-side *before* anything renders — never after the user has seen it.
- Treat the parser as a known liability, log every parse miss, and rip it out the moment a tool channel exists.
- Don't teach the marker by stuffing instructions into the user turn / chat bubble — that's another leak and it conditions the model to echo it. Put it in the system prompt.

## Method when one is already leaking

Don't patch the regex to catch the latest phrasing — that's re-fighting the symptom. Trace it: the tag is in the reply because the design put it there. The fix is to delete the tag-and-parser pair and register the tool, then remove the now-dead extraction path (no back-compat marker handling left behind). Verify by driving the real flow and confirming the transcript is clean and the action still fires — a passing unit test on the parser proves nothing once the parser is meant to be gone.

## Sources

- Transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/15/rollout-2026-06-15T18-35-52-019ece12-13fd-7d91-8e29-aed11614e297.jsonl:28120-28126` shows a Clippy menu implementation reporting `Return only a JSON object` in the app prompt, followed by user pushback asking why it was not a custom tool call or equivalent structured channel.
- OpenAI function calling docs: tool calling sends a separate tool call to the application, which executes code with the tool-call input and continues the conversation.
- OpenAI structured outputs docs: use function calling for app functionality/tools/data, and use strict structured response formats when the model response itself needs a schema.
- Anthropic tool-use docs: Claude client tools are passed through the `tools` parameter with a name, description, and JSON Schema `input_schema`.
