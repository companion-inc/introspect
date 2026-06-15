import json
path="/Users/advaitpaliwal/.claude/projects/-Users-advaitpaliwal-Companion-Code-clippy/e815492e-813a-4022-af54-5f90f4a4163a.jsonl"
lines=open(path).read().splitlines()
def textof(c):
    if isinstance(c,str): return c
    out=[]
    for b in c:
        if isinstance(b,dict):
            if b.get('type')=='text': out.append(b.get('text',''))
            elif b.get('type')=='tool_use': out.append('[tool_use '+b.get('name','')+'] '+json.dumps(b.get('input',{}))[:500])
            elif b.get('type')=='tool_result':
                rc=b.get('content','')
                if isinstance(rc,list): rc=' '.join(x.get('text','') for x in rc if isinstance(x,dict))
                out.append('[tool_result] '+str(rc)[:500])
    return '\n'.join(out)
rows=[]
for line in lines:
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except: continue
    t=o.get('type')
    if t not in ('user','assistant'): continue
    msg=o.get('message',{})
    role=msg.get('role','')
    rows.append((role,textof(msg.get('content',''))))
for role,txt in rows[-26:]:
    print('==== '+role+' ====')
    print(txt[:1800])
    print()
