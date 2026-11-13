# SAGA 2D mesh smoke scene

A minimal project for the browser check of `AdaSprite.Mesh2D`, the 2D mesh Ada Studio authors: an orthographic
camera, a red `Quad` on the left and a green `Circle` on the right, each drawn with `ColorCanvasMaterial`.
It exercises the exporter-prelinked `mesh2d` and `color_canvas_material` WGSL variants in the browser.

1. Export the web player and pack this project into it, as described in the
   [3D smoke scene README](../SAGASmoke/README.md).
2. Run `node script/web_golden_saga.mjs <bundle> --mesh2d`. It waits for a settled frame, then requires saturated red
   pixels only on the left half, saturated green pixels only on the right half, and a black background elsewhere.
   Pass `--actual=<path.png>` to save the captured frame.
