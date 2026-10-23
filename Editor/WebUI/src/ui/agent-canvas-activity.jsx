import React from "react";
import { t } from "../localization.js";
import "./agent-canvas-activity.css";

function activityText(studio) {
  if (studio.permissionRequest) return t("Waiting for your approval…");
  const tool = studio.activity?.findLast(
    (entry) =>
      entry.status === "running" && entry.sessionID === studio.runningSessionID,
  )?.name;
  if (tool === "editor_build") return t("Checking the build…");
  if (/^editor_(sprite|audio|model|voxel)_generate$/.test(tool))
    return t("Creating assets…");
  if (/^editor_play_/.test(tool)) return t("Testing the game…");
  if (/^editor_file_(write|patch|delete)$/.test(tool))
    return t("Writing code…");
  if (
    /^editor_(scene_(apply|set|add)|project_apply|examples_apply|project_configure)$/.test(
      tool,
    ) ||
    studio.runtime === "loading"
  )
    return t("Updating the scene…");
  if (
    tool === "editor_plan_update" ||
    studio.chat?.sessions?.find(
      (session) => session.id === studio.runningSessionID,
    )?.mode === "plan"
  )
    return t("Planning the next steps…");
  if (tool) return t("Reading project context…");
  return t("Working on your game…");
}

// Fixed geometry: CSS moves and lights the dots without per-frame React updates.
const dots = Array.from({ length: 77 }, (_, index) => {
  const row = Math.floor(index / 11),
    column = index % 11;
  return {
    "--wave-delay": `${-(column * 0.13 + row * 0.09)}s`,
    "--dot-opacity": 0.35 + (1 - Math.abs(column - 5) / 6) * 0.55,
  };
});

export function AgentCanvasActivity({ studio, visible = true }) {
  if (!visible || !studio.running) return null;
  return (
    <div className="agent-canvas-activity">
      <div className="agent-canvas-progress">
        <div className="agent-canvas-wave" aria-hidden="true">
          {dots.map((style, index) => (
            <i key={index} style={style} />
          ))}
        </div>
        <p role="status" aria-live="polite" aria-atomic="true">
          {activityText(studio)}
        </p>
      </div>
    </div>
  );
}
