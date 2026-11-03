import json
import statistics
import sys
from pathlib import Path

path = Path(sys.argv[1])
cases = json.loads(path.read_text(encoding="utf-8"))
assert len(cases) == 18
assert len({(c['width'], c['height']) for c in cases}) == 1
assert all(c['shadowCascadeResolution'] == 2048 and c['localShadowResolution'] == 1024 for c in cases)
assert all(c.get('shadowDistance') == 80 for c in cases)
rows = []
for view in ['gallery', 'outside']:
    for error in [0, 2, 8]:
        runs = []
        for c in cases:
            if c['view'] != view or c['meshletLODPixelError'] != error:
                continue
            v = c['publishedIntervalsMilliseconds']
            main = [n['durationMilliseconds'] for r in c['graphRecords'] for n in r['nodes'] if n['label'] == 'Main3DRenderNode']
            s = next(iter(c['meshlets'].values()))
            if error > 0:
                assert s['lodGPUItems'] > 0, s
            runs.append(dict(round=c['round'], fps=1000/statistics.mean(v), meanMs=statistics.mean(v),
                p95Ms=sorted(v)[int(.95*(len(v)-1))], mainCPUEncodeMedianMs=statistics.median(main),
                gpuIndexCount=c.get('meshletGPUIndexCount'), state=s))
        assert len(runs) == 3
        row = dict(view=view, pixelError=error, fpsMedian=statistics.median(r['fps'] for r in runs),
            meanMsMedian=statistics.median(r['meanMs'] for r in runs), p95MsMedian=statistics.median(r['p95Ms'] for r in runs),
            cpuMedianMs=statistics.median(r['mainCPUEncodeMedianMs'] for r in runs), runs=runs)
        rows.append(row)
        print(view, error, 'fps', round(row['fpsMedian'],2), 'mean/p95 ms',round(row['meanMsMedian'],3),round(row['p95MsMedian'],3),
            'CPU', round(row['cpuMedianMs'],3), 'GPU index samples',[r['gpuIndexCount'] for r in runs])
result = dict(source=path.name, resolution=[cases[0]['width'],cases[0]['height']], cases=len(cases),
    shadowCascadeResolution=2048, localShadowResolution=1024, shadowDistance=80, summary=rows)
path.with_name(path.stem+'-summary.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
