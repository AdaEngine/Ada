# Desktop toolbar and sidebar icon size

Status **Accepted**

Center the native macOS traffic lights in the 34 pt workspace toolbar. Use the existing window title-bar offset for both methods of opening a project. Preserve the welcome window's title-bar behavior.

Replace the desktop Editor and Agent segmented picker with a 26 pt icon button. Show the current mode using the bundled code or sparkles symbol. Clicking the button switches to the other mode. Give the action a localized tooltip and keyboard focus indication. Keep the existing workspace state and shortcuts when switching.

Use a single compact trailing toolbar group with 4 pt spacing. The AI credits, build target, run destination and run controls use the toolbar surface at rest in desktop Studio. Keep the build target and run destination labels and disclosure arrows, existing menu behavior, and all current icon colors. Button hover, press, focus and disabled states remain visible. Narrow screens keep all critical actions reachable.

In **Settings > General > Appearance**, add **Larger sidebar icons** using the existing settings toggle. Off uses the compact 14 pt icon size and On uses 18 pt. Apply immediately to both desktop sidebar tool strips and persist the choice globally with the existing appearance preferences. Keep each toolbar button's 26 pt target, icon color, and selected state. Both labels and tooltips have English and Russian strings.

Verify the running toolbar on macOS in both modes and at normal and narrow sizes. Compare both icon settings and confirm the chosen size survives a relaunch. Update **Explore and edit** in the Studio editor guide and regenerate the offline catalog. The toolbar geometry and setting share the native desktop workbench, and Windows and Linux need corresponding runtime checks.
