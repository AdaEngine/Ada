# Compact desktop workspace for Ada Studio

Status **Accepted**
Base `36e35198f`
Scope **Native desktop workspace**

## Outcome

Give the scene or document more room by removing the empty gutters between panels and reducing the visual weight of toolbar controls and tabs. Use the panel seams and compact chrome in the supplied Zed and Delta screenshots as references. Keep the Studio workspace structure, theme tokens, text roles and existing icon colors. The Godot screenshot illustrates how colored entity and asset icons stay legible alongside compact editor controls.

The desktop workspace retains the project navigator, scene hierarchy, document area, inspector, bottom dock and tool strips. Use a single 1 pt themed divider at each visible panel boundary and remove surrounding panel insets and card radii. The divider has a wider, invisible resize target. Its hit area stays clear of controls, and it remains usable on hover and during a drag. Existing pane collapse, persisted sizes and narrow-window rules continue to apply.

## Controls

- Use 13–14 pt Material Symbols on desktop workbench tool strips, viewport tools, tabs and tree rows. Keep a 26–28 pt target for toolbar icon buttons. Preserve each file, entity, selection and command color at its existing site, including Run, Debug and Stop. Retain the original disabled emphasis and colored Inspector axis badges.
- Make document and dock tabs rectangular. Use an edge and the existing accent to identify the active tab. Render tree selection as a full-width row. Keep selection visible when the pointer leaves.
- Use a 3 pt radius for compact toolbar controls and themed search and numeric fields. Preserve visible borders for fields and command buttons that need a resting surface. Show hover, pressed and keyboard focus through the existing theme. Keep the white insertion caret in the dark theme. The New File button beside Targets shows its blue plus directly on the header in the resting state and uses the standard hover and focus feedback.
- Leave room for text, close buttons, tooltips and scroll indicators. Resizing and collapsing panes must continue to work with long English and Russian labels.

Zero-width seams would obscure panel boundaries. Rounded cards with narrower gutters would keep the empty bands around the workspace. A visible one-point seam with a wider drag target provides a clear boundary without reserving gutter space.

## Ownership and platform coverage

Use the existing AdaUI workspace layout, split-handle code, editor chrome and shared control styles. Keep the metrics scoped to native desktop and leave iOS and visionOS sizing and the separate browser shell outside this proposal. On desktop use existing resizing and accessibility entry points, and retain keyboard shortcuts and focus behavior.

## Acceptance and documentation

Use the rendered mockups for the normal and narrow layouts. These illustrate the intended appearance and include sample content and control states. Validate the running editor on each affected desktop platform. Exercise open and closed panels, resizing, normal and narrow windows, English and Russian, text scaling, selected/hovered/pressed/focused/disabled controls, dropdown dismissal, scroll indicators and the dark-theme caret. Open a scene and a text or asset tab and verify that selection, existing icon tint and input still behave as before. Run the contribution checks and obtain independent review for the implementation.

Update **Explore and edit** in `Editor/Documentation/EditorGuide.md` with the location and operation of the desktop panel dividers. Use the existing editor-guide navigation and rebuild or verify the offline documentation catalog through the repository tooling. Use the Bench scene and its source and asset tabs as the verification example.
