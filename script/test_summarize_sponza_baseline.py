import copy
import unittest

from summarize_sponza_baseline import summarize


class SponzaSummaryTests(unittest.TestCase):
    def report(self):
        samples = []
        for round_index in range(3):
            for hiz in (False, True):
                samples.append({
                    "preset": "sponza-base", "quality": "geometry", "route": "atrium", "hiZ": hiz, "round": round_index,
                    "updateMilliseconds": [1, 2, 3], "windowMillisecondsPerFrame": [2],
                    "extractionMilliseconds": [1], "listPreparationMilliseconds": [1], "mainNodeMilliseconds": [1],
                    "drainInclusiveMillisecondsPerFrame": round_index + 1, "gpuPasses": [],
                    "census": {"batches": 10, "triangles": 1000, "compactedIndexCeilingBytes": 12000},
                })
        return {"schema": 1, "complete": True, "backend": "test", "width": 1280, "height": 720,
                "cameraPoseProtocol": "same-frame-root-world-pose-v1",
                "warmup": 60, "frames": 3, "rounds": 3, "submissionWindowFrames": 3,
                "completionProtocol": "test", "measurements": samples}

    def test_uses_all_rounds_and_labels_gpu_limitation(self):
        value = summarize(self.report())
        self.assertIn("| False | 2.000 |", value)
        self.assertIn("GPU pass timestamp samples: 0", value)
        self.assertIn("not individual frame latency", value)

    def test_incomplete_report_or_pairs_are_rejected(self):
        report = self.report()
        report["complete"] = False
        with self.assertRaises(ValueError):
            summarize(report)
        report = self.report()
        report.pop("cameraPoseProtocol")
        with self.assertRaises(ValueError):
            summarize(report)
        report = self.report()
        report["measurements"].pop()
        with self.assertRaises(ValueError):
            summarize(report)
        report = self.report()
        report["measurements"] = [s for s in report["measurements"] if s["hiZ"]]
        with self.assertRaises(ValueError):
            summarize(report)

    def test_corrupt_or_inconsistent_samples_are_rejected(self):
        for field, value in [("updateMilliseconds", [float("nan"), 1, 2]),
                             ("updateMilliseconds", [1]), ("drainInclusiveMillisecondsPerFrame", -1)]:
            report = self.report()
            report["measurements"][0][field] = value
            with self.assertRaises(ValueError):
                summarize(report)
        report = self.report()
        report["measurements"].append(copy.deepcopy(report["measurements"][0]))
        with self.assertRaises(ValueError):
            summarize(report)
        report = self.report()
        report["measurements"][0]["census"]["triangles"] = 999
        with self.assertRaises(ValueError):
            summarize(report)


if __name__ == "__main__":
    unittest.main()
