import json
import statistics
import sys
from pathlib import Path

source = Path(sys.argv[1])
cases = json.loads(source.read_text(encoding="utf-8"))
assert len(cases) == 18, len(cases)
assert len({(c["width"], c["height"]) for c in cases}) == 1
summary = []
for view in ("gallery", "outside"):
    for mode in ("disabled", "cpuReference", "gpu"):
        selected = [c for c in cases if c["view"] == view and any(s["mode"] == mode for s in c["meshlets"].values())]
        assert len(selected) == 3, (view, mode, len(selected))
        runs = []
        for case in selected:
            intervals = case["publishedIntervalsMilliseconds"]
            assert len(intervals) > 0
            values = sorted(intervals)
            main = [n["durationMilliseconds"] for record in case["graphRecords"] for n in record["nodes"] if n["label"] == "Main3DRenderNode"]
            state = next(iter(case["meshlets"].values()))
            runs.append(dict(round=case["round"], samples=len(intervals), fps=1000/statistics.mean(intervals),
                meanMs=statistics.mean(intervals), medianMs=statistics.median(intervals), p95Ms=values[int(.95*(len(values)-1))],
                mainCPUEncodeMedianMs=statistics.median(main), gpuIndexCount=case.get("meshletGPUIndexCount"), state=state))
        summary.append(dict(view=view, mode=mode, fpsMedian=statistics.median(r["fps"] for r in runs),
            meanMsMedian=statistics.median(r["meanMs"] for r in runs),
            p95MsMedian=statistics.median(r["p95Ms"] for r in runs),
            mainCPUEncodeMedianMs=statistics.median(r["mainCPUEncodeMedianMs"] for r in runs), runs=runs))
result = dict(source=source.name, resolution=[cases[0]["width"], cases[0]["height"]], cases=len(cases), summary=summary)
destination = source.with_name(source.stem + "-summary.json")
destination.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
for row in summary:
    print(row["view"], row["mode"], "FPS", round(row["fpsMedian"],2), "mean/p95 ms",round(row["meanMsMedian"],3),round(row["p95MsMedian"],3),"CPU",round(row["mainCPUEncodeMedianMs"],3),"runs",[round(r["fps"],2) for r in row["runs"]])
print(destination)
