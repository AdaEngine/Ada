// Recipe executed by the embedded AdaScript VM. No process, file access, JIT or Swift compilation.
func rigHasParent(model, partId, name) {
    while (partId >= 0) {
        if (model.partName(partId) == name) { return true; }
        partId = model.partParent(partId);
    }
    return false;
}

func rigRigidJoint(model, partId, joints) {
    var name = model.partName(partId);
    if (rigHasParent(model, partId, "Broken sword")) { return joints[18]; }
    if (rigHasParent(model, partId, "Round shield")) { return joints[22]; }
    if (rigHasParent(model, partId, "Lower jaw")) { return joints[6]; }
    if (rigHasParent(model, partId, "Head")) { return joints[5]; }
    for (var side in 0..<2) {
        var leg = "Left leg";
        var arm = "Left arm";
        var hip = 7;
        var shoulder = 15;
        if (side == 1) {
            leg = "Right leg";
            arm = "Right arm";
            hip = 11;
            shoulder = 19;
        }
        if (rigHasParent(model, partId, leg)) {
            if (name == "Shorts leg" || name == "Leather cuff") { return joints[hip]; }
            if (name == "Shin" || name == "Knee") { return joints[hip + 1]; }
            return joints[hip + 2];
        }
        if (rigHasParent(model, partId, arm)) {
            if (name == "Shoulder" || name == "Humerus") { return joints[shoulder]; }
            if (name == "Hand") { return joints[shoulder + 3]; }
            return joints[shoulder + 1];
        }
    }
    if (rigHasParent(model, partId, "Terracotta neckerchief") || name == "Spine" || name == "Sternum") { return joints[2]; }
    if (rigHasParent(model, partId, "Rib cage row 1")) { return joints[2]; }
    if (rigHasParent(model, partId, "Torso")) { return joints[3]; }
    if (rigHasParent(model, partId, "Pelvis and belt")) { return joints[1]; }
    assert(false, "No weight rule for " + name);
    return joints[0];
}

func rigSkinParts(model, joints) {
    for (var partId in 0..<model.partCount()) {
        if (!model.hasMesh(partId)) { continue; }
        model.bind(partId, rigRigidJoint(model, partId, joints));
        var name = model.partName(partId);
        var scarf = rigHasParent(model, partId, "Terracotta neckerchief") || name == "Spine" || name == "Sternum";
        if (!scarf && name != "Dark shorts") { continue; }
        for (var vertex in 0..<model.vertexCount(partId)) {
            var y = model.vertexPosition(partId, vertex, 1);
            if (scarf) {
                var amount = Math.clamp((y - 0.63) / 0.28, 0, 1);
                model.weights(partId, vertex, joints[2], 1 - amount, joints[3], amount);
            } else {
                var x = model.vertexPosition(partId, vertex, 0);
                var amount = Math.clamp((0.43 - y) / 0.14, 0, 1) * Math.clamp(Math.abs(x) / 0.11, 0, 1);
                var hip = joints[11];
                if (x < 0) { hip = joints[7]; }
                model.weights(partId, vertex, joints[1], 1 - amount, hip, amount);
            }
        }
    }
}

func rigLegAngles(phase, hipHeight) {
    var pi = 3.141592653589793;
    var stance = phase < 0.5;
    var progress = phase * 2;
    var z = -0.075 + 0.15 * progress;
    var lift = 0;
    if (!stance) {
        progress = (phase - 0.5) * 2;
        z = 0.075 - 0.15 * progress;
        lift = 0.035 * Math.sin(pi * progress);
    }
    var dy = hipHeight - (0.12 + lift);
    var dz = z - 0.015;
    var upper = 0.08;
    var lower = Math.sqrt(0.14 * 0.14 + 0.015 * 0.015);
    var distance = Math.min(Math.sqrt(dy * dy + dz * dz), upper + lower - 0.00001);
    var knee = -Math.acos(Math.clamp((distance * distance - upper * upper - lower * lower) / (2 * upper * lower), -1, 1));
    var hip = Math.atan2(-dz, dy) - Math.atan2(lower * Math.sin(knee), upper + lower * Math.cos(knee));
    var rest = Math.atan2(0.015, 0.14);
    return [hip * 180 / pi, (knee - rest) * 180 / pi, (rest - hip - knee) * 180 / pi];
}

func rigWalkClips(model, joints) {
    var bind = model.clip("BindPose");
    for (var joint in joints) {
        model.rotationKey(bind, joint, 0, 0, 0, 0);
        model.rotationKey(bind, joint, 1.2, 0, 0, 0);
    }
    model.translationKey(bind, joints[1], 0, 0, 0.39, 0);
    model.translationKey(bind, joints[1], 1.2, 0, 0.39, 0);
    var walk = model.clip("Walk");
    for (var key in 0..<49) {
        var time = key * 1.2 / 48.0;
        var phase = key / 48.0;
        if (key == 48) { phase = 0; }
        var cycle = phase * 2 * 3.141592653589793;
        var bob = -0.025 + 0.004 * Math.cos(2 * cycle);
        var rightPhase = phase + 0.5;
        if (rightPhase >= 1) { rightPhase = rightPhase - 1; }
        var left = rigLegAngles(phase, 0.34 + bob);
        var right = rigLegAngles(rightPhase, 0.34 + bob);
        model.translationKey(walk, joints[1], time, 0, 0.39 + bob, 0);
        model.rotationKey(walk, joints[7], time, left[0], 0, 0);
        model.rotationKey(walk, joints[8], time, left[1], 0, 0);
        model.rotationKey(walk, joints[9], time, left[2], 0, 0);
        model.rotationKey(walk, joints[11], time, right[0], 0, 0);
        model.rotationKey(walk, joints[12], time, right[1], 0, 0);
        model.rotationKey(walk, joints[13], time, right[2], 0, 0);
        model.rotationKey(walk, joints[2], time, 1.2 * Math.sin(2 * cycle), 2.5 * Math.sin(cycle), 0);
        model.rotationKey(walk, joints[3], time, 0, -4 * Math.sin(cycle), 1.8 * Math.sin(cycle));
        model.rotationKey(walk, joints[5], time, 0, 1.5 * Math.sin(cycle), -1.8 * Math.sin(cycle));
        model.rotationKey(walk, joints[6], time, 2 + Math.sin(2 * cycle), 0, 0);
        model.rotationKey(walk, joints[15], time, -12 * Math.cos(cycle), 0, 43);
        model.rotationKey(walk, joints[19], time, 12 * Math.cos(cycle), 0, -43);
        model.rotationKey(walk, joints[16], time, -7 - 4 * Math.sin(cycle), 0, 0);
        model.rotationKey(walk, joints[20], time, -7 + 4 * Math.sin(cycle), 0, 0);
        model.rotationKey(walk, joints[17], time, 0, 0, -43);
        model.rotationKey(walk, joints[21], time, 0, 0, 43);
    }
}

func build(model) {
    buildStaticSkeleton(model);
    var joints = [];
    joints.push(model.joint("Rig.root", -1, 0, 0, 0));
    joints.push(model.joint("Rig.hips", joints[0], 0, 0.39, 0));
    joints.push(model.joint("Rig.spine", joints[1], 0, 0.29, 0));
    joints.push(model.joint("Rig.chest", joints[2], 0, 0.22, 0));
    joints.push(model.joint("Rig.neck", joints[3], 0, 0.105, 0));
    joints.push(model.joint("Rig.head", joints[4], 0, 0.135, 0));
    joints.push(model.joint("Rig.jaw", joints[5], 0, -0.15, -0.1));
    joints.push(model.joint("Rig.leftHip", joints[1], -0.14, -0.05, 0));
    joints.push(model.joint("Rig.leftKnee", joints[7], 0, -0.08, 0));
    joints.push(model.joint("Rig.leftAnkle", joints[8], 0, -0.14, -0.015));
    joints.push(model.joint("Rig.leftToe", joints[9], 0, -0.07, -0.145));
    joints.push(model.joint("Rig.rightHip", joints[1], 0.14, -0.05, 0));
    joints.push(model.joint("Rig.rightKnee", joints[11], 0, -0.08, 0));
    joints.push(model.joint("Rig.rightAnkle", joints[12], 0, -0.14, -0.015));
    joints.push(model.joint("Rig.rightToe", joints[13], 0, -0.07, -0.145));
    joints.push(model.joint("Rig.leftShoulder", joints[3], -0.31, 0.01, 0));
    joints.push(model.joint("Rig.leftElbow", joints[15], -0.18, -0.05, -0.012));
    joints.push(model.joint("Rig.leftWrist", joints[16], -0.17, 0, -0.033));
    joints.push(model.joint("Rig.leftHand", joints[17], -0.04, 0, 0));
    joints.push(model.joint("Rig.rightShoulder", joints[3], 0.31, 0.01, 0));
    joints.push(model.joint("Rig.rightElbow", joints[19], 0.18, -0.05, -0.012));
    joints.push(model.joint("Rig.rightWrist", joints[20], 0.17, 0, -0.033));
    joints.push(model.joint("Rig.rightHand", joints[21], 0.04, 0, 0));
    rigSkinParts(model, joints);
    rigWalkClips(model, joints);
}
