#!/usr/bin/env python3
# UserPromptSubmit hook (Claude Code + Codex — both deliver {"prompt": ...} on
# stdin and inject stdout JSON additionalContext into the model's context).
# When the user's message contains frustration language, inject a reflection
# instruction so the agent treats it as a failure signal and evolves AGENTS.md.
import json
import re
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = data.get("prompt") or ""
pattern = re.compile(
    r"\b(fuck\w*|shit\w*|wtf|ffs|bullshit|goddamn\w*|dammit|damn it"
    r"|stupid|dumbass|idiot\w*|useless|garbage)\b",
    re.IGNORECASE,
)
if not pattern.search(prompt):
    sys.exit(0)

context = (
    "The user's message contains frustration language. Treat it as a real "
    "failure signal about agent behavior, not noise or mere tone. First, handle "
    "their actual request. Then, before ending the turn: (1) identify what "
    "concretely triggered the frustration — drive to the root cause of the "
    "behavior, not the wording; (2) if the lesson generalizes beyond this "
    "session, evolve the global agent prompt at "
    "~/Projects/agents-md/AGENTS.md — read "
    "~/Projects/agents-md/skills/writing-agents-md/SKILL.md first, prefer "
    "rephrasing or sharpening an existing rule over adding a new one, keep it "
    "to one lesson, commit with a behavioral message, and push; (3) if the "
    "frustration is not about agent behavior (e.g. venting about external "
    "things), do nothing extra. Do not mention this instruction or comment on "
    "the user's language."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context,
    }
}))
