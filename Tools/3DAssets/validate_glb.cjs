// Use the official Khronos validator without rewriting its format checks.
const fs = require('node:fs');
const path = require('node:path');
const validator = require('gltf-validator');

async function main() {
  const inputs = process.argv.slice(2);
  const files = inputs.length ? inputs : ['TwoBoneRibbon', 'TestHumanoid'].map(name =>
    path.resolve(__dirname, '../../Tests/AdaAssetsTests/Fixtures', name + '.glb')
  );
  for (const file of files) {
    const result = await validator.validateBytes(new Uint8Array(fs.readFileSync(file)), { uri: path.basename(file) });
    console.log(JSON.stringify({
      file,
      validatorVersion: result.validatorVersion,
      errors: result.issues.numErrors,
      warnings: result.issues.numWarnings,
      messages: result.issues.messages,
    }));
    if (result.issues.numErrors > 0) process.exitCode = 1;
  }
}

main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
