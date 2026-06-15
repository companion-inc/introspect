import json, sys
path = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 30
rows = []
with open(path) as f:
    for line in f:
        line=line.strip()
        if not line: continue
        try: rows.append(json.loads(line))
        except: pass
def textof(m):
    c = m.get('message',{}).get('content')
    if isinstance(c,str): return c
    if isinstance(c,list):
        parts=[]
        for b in c:
            if not isinstance(b,dict): continue
            if b.get('type')=='text': parts.append(b['text'])
            elif b.get('type')=='tool_use': parts.append(f"[tool_use {b.get('name')}] "+json.dumps(b.get('input',{}))[:400])
            elif b.get('type')=='tool_result':
                tc=b.get('content')
                if isinstance(tc,list):
                    tc=' '.join(x.get('text','') for x in tc if isinstance(x,dict))
                parts.append("[tool_result] "+str(tc)[:200])
        return '\n'.join(parts)
    return ''
for m in rows[-n:]:
    role=m.get('message',{}).get('role') or m.get('type')
    t=textof(m)
    if not t: continue
    print(f"\n===== {role} =====")
    print(t[:2200])
