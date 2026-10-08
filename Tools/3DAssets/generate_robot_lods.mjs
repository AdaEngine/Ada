// Index-only simplification: preserve the legacy FBX rig, vertices, weights and bind matrices.
// npm install --prefix /tmp/ada-meshopt meshoptimizer@1.2.0
// MESHOPTIMIZER_MODULE=/tmp/ada-meshopt/node_modules/meshoptimizer/index.js node Tools/3DAssets/generate_robot_lods.mjs
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const { MeshoptSimplifier } = await import(process.env.MESHOPTIMIZER_MODULE || 'meshoptimizer');
await MeshoptSimplifier.ready;
const root = fileURLToPath(new URL('../../Demos/SkeletalGarden/', import.meta.url));
const input = await readFile(root + 'Assets/GardenRobot.glb');
if (input.readUInt32LE(0) !== 0x46546c67 || input.readUInt32LE(4) !== 2) throw new Error('Expected GLB 2');
const jsonSize = input.readUInt32LE(12);
const base = JSON.parse(input.subarray(20, 20 + jsonSize).toString());
const binOffset = 20 + jsonSize + 8;
const binary = input.subarray(binOffset, binOffset + input.readUInt32LE(20 + jsonSize));
function accessor(id) {
  const a = base.accessors[id], view = base.bufferViews[a.bufferView];
  if (a.sparse || view.buffer !== 0) throw new Error('Unsupported accessor storage');
  const lanes = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4 }[a.type];
  const bytes = { 5121: 1, 5123: 2, 5125: 4, 5126: 4 }[a.componentType];
  if (!lanes || !bytes) throw new Error('Unsupported accessor format');
  const values = new Float32Array(a.count * lanes);
  for (let i = 0; i < a.count; i++) for (let j = 0; j < lanes; j++) {
    const at = (view.byteOffset || 0) + (a.byteOffset || 0) + i * (view.byteStride || bytes * lanes) + j * bytes;
    let value = a.componentType === 5126 ? binary.readFloatLE(at) : bytes === 4 ? binary.readUInt32LE(at) : bytes === 2 ? binary.readUInt16LE(at) : binary[at];
    if (a.normalized) value /= bytes === 1 ? 255 : 65535;
    values[i * lanes + j] = value;
  }
  return values;
}
const report = { sourceSHA256: createHash('sha256').update(input).digest('hex'), tool: 'meshoptimizer 1.2.0', variants: [] };
for (const [level, ratio, error] of [[1, 0.65, 0.025], [2, 0.35, 0.06]]) {
  const json = structuredClone(base), chunks = [binary];
  let length = binary.length, before = 0, after = 0;
  for (let m = 0; m < json.meshes.length; m++) for (let p = 0; p < json.meshes[m].primitives.length; p++) {
    const primitive = json.meshes[m].primitives[p];
    if ((primitive.mode ?? 4) !== 4) throw new Error('Expected triangles');
    const positions = accessor(primitive.attributes.POSITION);
    const original = primitive.indices === undefined ? Uint32Array.from({ length: positions.length / 3 }, (_, i) => i) : Uint32Array.from(accessor(primitive.indices));
    const normal = primitive.attributes.NORMAL === undefined ? null : accessor(primitive.attributes.NORMAL);
    const weights = primitive.attributes.WEIGHTS_0 === undefined ? null : accessor(primitive.attributes.WEIGHTS_0);
    const joints = primitive.attributes.JOINTS_0 === undefined ? null : accessor(primitive.attributes.JOINTS_0);
    const stride = (normal ? 3 : 0) + (weights ? 8 : 0);
    const attributes = new Float32Array(positions.length / 3 * stride), importance = [];
    if (normal) importance.push(0.1, 0.1, 0.1);
    if (weights) importance.push(2, 2, 2, 2, 1, 1, 1, 1);
    for (let i = 0; i < positions.length / 3; i++) {
      let at = i * stride;
      if (normal) for (let j = 0; j < 3; j++) attributes[at++] = normal[i * 3 + j];
      if (weights) {
        for (let j = 0; j < 4; j++) attributes[at++] = weights[i * 4 + j];
        for (let j = 0; j < 4; j++) attributes[at++] = joints[i * 4 + j] * weights[i * 4 + j];
      }
    }
    const target = Math.max(3, Math.floor(original.length * ratio / 3) * 3);
    let [indices] = MeshoptSimplifier.simplifyWithAttributes(original, positions, 3, attributes, stride, importance, null, target, error, ['Permissive', 'Regularize']);
    if (!indices.length) indices = original;
    before += original.length / 3; after += indices.length / 3;
    const padding = (4 - length % 4) % 4;
    if (padding) { chunks.push(Buffer.alloc(padding)); length += padding; }
    const data = Buffer.alloc(indices.length * 4);
    indices.forEach((index, i) => data.writeUInt32LE(index, i * 4));
    const view = json.bufferViews.push({ buffer: 0, byteOffset: length, byteLength: data.length, target: 34963 }) - 1;
    primitive.indices = json.accessors.push({ bufferView: view, componentType: 5125, type: 'SCALAR', count: indices.length, min: [Math.min(...indices)], max: [Math.max(...indices)] }) - 1;
    chunks.push(data); length += data.length;
  }
  if (JSON.stringify(json.skins) !== JSON.stringify(base.skins) || JSON.stringify(json.nodes) !== JSON.stringify(base.nodes) || JSON.stringify(json.animations) !== JSON.stringify(base.animations)) throw new Error('Rig or animation changed');
  json.buffers[0].byteLength = length;
  const rawJSON = Buffer.from(JSON.stringify(json)), jsonPad = Buffer.alloc((4 - rawJSON.length % 4) % 4, 0x20);
  const rawBIN = Buffer.concat(chunks), binPad = Buffer.alloc((4 - rawBIN.length % 4) % 4);
  const total = 12 + 8 + rawJSON.length + jsonPad.length + 8 + rawBIN.length + binPad.length;
  const header = Buffer.alloc(20); header.writeUInt32LE(0x46546c67, 0); header.writeUInt32LE(2, 4); header.writeUInt32LE(total, 8); header.writeUInt32LE(rawJSON.length + jsonPad.length, 12); header.writeUInt32LE(0x4e4f534a, 16);
  const binHeader = Buffer.alloc(8); binHeader.writeUInt32LE(rawBIN.length + binPad.length, 0); binHeader.writeUInt32LE(0x004e4942, 4);
  await writeFile(root + `Assets/GardenRobotLOD${level}.glb`, Buffer.concat([header, rawJSON, jsonPad, binHeader, rawBIN, binPad]));
  report.variants.push({ level, targetRatio: ratio, maximumError: error, baseTriangles: before, triangles: after });
}
await writeFile(root + 'SourceAssets/robot-lods.json', JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report));
