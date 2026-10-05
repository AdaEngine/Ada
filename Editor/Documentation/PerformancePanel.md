# Game Performance panel

Open the bottom panel with the **Output** tool, then select **Performance**. Run a scene or an AdaScript project inside AdaEditor. The game title opens a session selector. **Overview** shows live charts and aggregate hotspots. **Timeline** inspects completed CPU captures. **Expand** opens Performance in the central workspace; **Return to editor** restores the document workspace and bottom panel.

Choose **Delay** (0–60 seconds) and **Duration** (1–120 seconds), then **Record**. A scheduled recording is pinned to that game session and starts even if the panel is hidden. **Cancel scheduled**, selecting another session, or stopping the scheduled game cancels the pending start. If another capture starts first, the pending recording reports the profiler's busy error. Once recording begins, **Stop recording** completes it early; otherwise the profiler completes it after the chosen duration. Completed captures for the selected game can be selected and exported as Chrome Trace JSON.

The timeline draws the capture's actual complete spans, ordered by start time, on lanes for updates, render graphs, render nodes, ECS systems and schedulers. Render nodes with the same name in different graphs have separate lanes. Concurrent calls occupy separate rows. **All / Rendering / ECS** filters lanes; **+ / −** zoom, **‹ / ›** move through time, and **Fit** restores the whole capture. Click a bar to inspect its start, end, duration, graph and node type (when recorded). **Focus call** zooms around the selected call. Very short calls have a minimum visual width so they can be selected; their numeric duration remains exact. Capture selection resets the timeline's view and event selection.

The panel shows:

- game updates per second, calculated from intervals between update starts;
- elapsed CPU update time and p95, including the game's nested render-world work;
- process memory in MiB (shared by AdaEditor and embedded games);
- entities in the game's root world;
- ECS-system and CPU render-node durations, sorted by total time.

These measurements do not report GPU execution time or display FPS. Concurrent system durations may overlap and must not be added to estimate frame latency. `No data` indicates an unavailable measurement. A sampled p95 is marked `≈` if a live bucket exceeds its 4,096-duration percentile sample limit; counts, mean, total and maximum remain exact.

Live history is bounded to 240 samples and 60 seconds, refreshed at 4 Hz. Closing the last Performance presentation releases its live recording lease. Moving between the panel and workspace preserves the game's viewport and the live subscription. Scheduled starts and active captures continue while the panel is hidden. MCP readers and detailed captures retain their own leases. Stopping a game completes its active capture and retains the final history. A new run gets a new target ID. Completed captures are retained for the last eight recordings during the editor process lifetime.

## MCP

`profiler.list_targets` returns game sessions. Pass a returned ID as `targetId` to `profiler.live_snapshot` or `profiler.start_capture`. Repeated targeted live requests keep a three-second recording lease alive. A targeted snapshot contains the same typed session and samples used by the panel.

```json
{"name":"profiler.live_snapshot","arguments":{"targetId":"<game-session-id>"}}
```

```json
{"name":"profiler.start_capture","arguments":{"targetId":"<game-session-id>","durationMs":5000}}
```

Use `profiler.list_captures`, `profiler.get_capture` and `profiler.stop_capture` for recordings. The capture manifest includes `targetId`. Only one detailed capture runs at a time, shared by the panel and MCP.

Calls without `targetId` retain their existing process-wide scope and legacy payload. The legacy `fps` field remains for compatibility; use `updateRateHz` for update cadence in capture summaries.

AdaPlayer, external Swift processes and GPU resource counters are outside this version.
