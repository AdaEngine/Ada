import collections
import json
import statistics
import sys
from pathlib import Path

stem=Path(sys.argv[1])
events=[]
markers=[]
for line in stem.with_suffix('.stdout.log').read_text(encoding='utf-8',errors='replace').splitlines():
    p=line.split('\t')
    try:
        if p[0]=='ADA_STALL': events.append(dict(start=float(p[1]),ms=float(p[2]),name=p[3],bytes=int(p[4]),count=int(p[5])))
        elif p[0]=='ADA_STALL_PHASE': markers.append((float(p[1]),p[2]))
    except (ValueError,IndexError): pass
phases=json.loads(stem.with_suffix('.json').read_text(encoding='utf-8')) if stem.with_suffix('.json').exists() else []
result=[]
for phase in phases:
    name=phase['name']; v=sorted(phase['publishedIntervalsMilliseconds'])
    if not v: continue
    begin=next(t for t,m in markers if m=='begin:'+name)
    end=next(t for t,m in markers if m=='end:'+name)
    inside=[e for e in events if begin<=e['start']<end]
    groups=collections.defaultdict(list)
    for e in inside: groups[e['name']].append(e)
    slow=sorted((dict(name=k,count=len(a),maximum=max(e['ms'] for e in a),over100=sum(e['ms']>100 for e in a)) for k,a in groups.items()),key=lambda e:e['maximum'],reverse=True)
    nodes=[n for r in phase['graphRecords'] for n in r['nodes']]
    worst_nodes=sorted(nodes,key=lambda n:n['durationMilliseconds'],reverse=True)[:5]
    r=dict(name=name,resolution=[phase['width'],phase['height']],sizeChanged=phase['sizeChanged'],samples=len(v),fps=1000/statistics.mean(v),
        p50=statistics.median(v),p95=v[int(.95*(len(v)-1))],p99=v[int(.99*(len(v)-1))],maximum=max(v),
        over50=sum(x>50 for x in v),over100=sum(x>100 for x in v),over200=sum(x>200 for x in v),slowOperations=slow,
        worstNodes=[dict(name=n['label'],ms=n['durationMilliseconds']) for n in worst_nodes])
    result.append(r)
    print(name,'fps',round(r['fps'],1),'p95/max',round(r['p95'],2),round(r['maximum'],2),'spikes>100/200',r['over100'],r['over200'])
    print(' operations',[(e['name'],round(e['maximum'],2),e['count']) for e in slow[:6]])
    print(' nodes',r['worstNodes'][:3])
print('Largest CPU events:')
for e in sorted((e for e in events if 'CompletionLatency' not in e['name']),key=lambda e:e['ms'],reverse=True)[:18]: print(e)
stem.with_name(stem.name+'-summary.json').write_text(json.dumps(dict(phases=result,events=events),indent=2),encoding='utf-8')
