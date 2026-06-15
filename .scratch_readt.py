import json, sys

p = '/Users/advaitpaliwal/.codex/sessions/2026/06/12/rollout-2026-06-12T13-56-55-019ebd9f-9ff2-77a3-90a5-da2b7c5603ab.jsonl'
with open(p) as f:
    lines = f.readlines()
print('total lines:', len(lines))
events = []
for line in lines:
    try:
        events.append(json.loads(line))
    except Exception:
        continue
print('events:', len(events))

def summarize(ev):
    t = ev.get('type', '')
    role = ev.get('role', '')
    ts = ev.get('timestamp', '')
    payload = ev.get('payload', {}) or {}
    content = ev.get('content', '') or payload.get('content', '')
    text = ''
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict):
                text += (c.get('text', '') or c.get('content', '') or '') + ' | '
    elif isinstance(content, str):
        text = content
    if not text and payload:
        text = json.dumps(payload)[:600]
    return ts, t, role, text

start = int(sys.argv[1]) if len(sys.argv) > 1 else max(0, len(events)-80)
end = int(sys.argv[2]) if len(sys.argv) > 2 else len(events)

for ev in events[start:end]:
    ts, t, role, text = summarize(ev)
    print(f'--- {ts} {t}/{role} ---')
    print(text[:1500])
    print()
