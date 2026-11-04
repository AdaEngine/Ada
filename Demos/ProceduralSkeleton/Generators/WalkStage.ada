func build(model) {
    model.material(0, 0.035, 0.048, 0.065);
    model.surface(0, 0.05, 0.9);
    var stage = model.cylinder(1.15, 1.18, 0.045, 48);
    model.name(stage, "Turntable plinth");
    model.place(stage, 0, -0.0225, 0);
}
