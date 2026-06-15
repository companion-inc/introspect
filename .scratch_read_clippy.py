import json
p='/Users/advaitpaliwal/.claude/projects/-Users-advaitpaliwal-Companion-Code-clippy/f2e329d4-ec2b-4967-b065-49cd7c1a9495.jsonl'
rows=[json.loads(l) for l in open(p)]
print('total', len(rows))
for r in rows[-44:]:
    t=r.get('type')
    ts=r.get('timestamp','')
    msg=r.get('message',{}) or {}
    if t=='user':
        c=msg.get('content')
        if isinstance(c,list):
            txt=' '.join(x.get('text','') if isinstance(x,dict) else str(x) for x in c)
        else: txt=str(c)
        print('\n---USER',ts)
        print(txt[:700])
    elif t=='assistant':
        c=msg.get('content',[])
        out=[]
        for x in c:
            if isinstance(x,dict):
                if x.get('type')=='text': out.append('TEXT:'+x['text'][:500])
                elif x.get('type')=='tool_use': out.append('TOOL:'+x.get('name','')+' '+json.dumps(x.get('input',{}))[:160])
        print('\n===ASSISTANT',ts)
        print(' | '.join(out)[:900])
