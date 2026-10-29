"""Exercise the staged Windows console CLI without starting Studio or a GPU."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--studio', required=True, type=Path)
    parser.add_argument('--project', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    executable = args.studio.resolve() / 'adastudio.exe'
    checks = []
    environment = os.environ.copy()
    # Inspection/validation must work with only the shipped DLLs and System32.
    environment['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')

    def run(words, expected=0):
        started = time.perf_counter()
        command = [str(executable), *words, '--format', 'json']
        result = subprocess.run(command, capture_output=True, timeout=90, env=environment)
        assert result.returncode == expected, (words, result.returncode, result.stderr.decode(errors='replace'))
        report = json.loads(result.stdout)
        assert report['exitCode'] == expected and report['ok'] == (expected == 0), report
        assert 'Selected WebGPU adapter' not in result.stderr.decode(errors='replace')
        checks.append({'arguments': words, 'exitCode': expected, 'seconds': round(time.perf_counter()-started,3),
                       'scope': report.get('details',{}).get('validationScope'), 'diagnostics': report['diagnostics']})
        return report

    metadata = args.project.resolve() / '.ada/project.json'
    before = hashlib.sha256(metadata.read_bytes()).hexdigest()
    assert 'Windows:' in run(['--help'])['details']['help']
    run(['--version'])
    run(['project','inspect','--project',str(args.project.resolve())])
    project = run(['validate','--project',str(args.project.resolve())])
    assert project['details']['validationScope'] == 'metadata,adascript,entry-scene,runtime-bindings'
    assert hashlib.sha256(metadata.read_bytes()).hexdigest() == before
    run(['validate','--project',str(args.project.resolve()),'--unknown','x'],2)
    run(['build','--project',str(args.project.resolve()),'--target','macos'],4)
    with tempfile.TemporaryDirectory(prefix='Ada CLI проверка ') as temporary:
        root = Path(temporary)
        run(['inspect','--project',str(root/'missing')],3)
        fixture = root / 'Game with spaces'
        (fixture/'.ada').mkdir(parents=True)
        (fixture/'Sources').mkdir()
        (fixture/'Assets').mkdir()
        config = json.loads(metadata.read_text(encoding='utf-8'))
        config['project'].update(name='CLI Fixture',displayName='CLI Fixture',id=str(uuid.uuid4()),bundleIdentifier='org.adaengine.cli-fixture')
        config['runtime']['entry']={'scene':'Assets/Main.ascn'}
        config['editor']['startupScene']='Assets/Main.ascn'
        (fixture/'.ada/project.json').write_text(json.dumps(config),encoding='utf-8')
        (fixture/'Sources/Main.ada').write_text('func main() { return 42; }\n',encoding='utf-8')
        scene={'format':'ada.scene','schemaVersion':1,'scene':{'id':str(uuid.uuid4()),'name':'CLI Fixture'},'entities':[]}
        (fixture/'Assets/Main.ascn').write_text(json.dumps(scene),encoding='utf-8')
        run(['validate','--project',str(fixture)])
        (fixture/'Assets/Main.ascn').unlink()
        run(['validate','--project',str(fixture)],3)
    summary={'status':'passed','consoleExecutable':str(executable),'executableSHA256':hashlib.sha256(executable.read_bytes()).hexdigest(),
             'projectMetadataUnchanged':True,'cleanPATH':True,'externalCompilerRequiredForValidation':False,
             'checks':checks,'validationDetails':project['details']}
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    print(json.dumps({'status':'passed','checks':len(checks),'validationDetails':project['details']}))


if __name__ == '__main__':
    main()
