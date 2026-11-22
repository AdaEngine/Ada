// Integral of the authored exponential density along a world-space line of sight.
fn heightFogOpacity(density: f32, shape: vec4f, cameraHeight: f32, riseComponent: f32, distance: f32) -> f32 {
    let travel = max(distance - shape.z, 0.0);
    let rise = shape.x * riseComponent;
    let exponent = clamp(rise * travel, -60.0, 60.0);
    var pathFactor = travel;
    if abs(rise * travel) > 0.0001 {
        pathFactor = (1.0 - exp(-exponent)) / rise;
    }
    let baseDensity = density * exp(clamp(-shape.x * (cameraHeight - shape.y), -60.0, 60.0));
    return min(1.0 - exp(-baseDensity * pathFactor), shape.w);
}
