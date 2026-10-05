#!/usr/bin/env python3
"""Build, package and launch a native Swift AdaEngine Android app."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
ABIS = {"arm64-v8a": ("aarch64", "aarch64-linux-android"), "x86_64": ("x86_64", "x86_64-linux-android")}
SYSTEM_LIBRARIES = {"libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so", "libEGL.so", "libGLESv2.so", "libGLESv3.so", "libz.so", "libvulkan.so", "libaaudio.so", "libOpenSLES.so"}
ANDROID = "{http://schemas.android.com/apk/res/android}"
ACTIVITY = "android.app.NativeActivity"
ET.register_namespace("android", "http://schemas.android.com/apk/res/android")

class AndroidError(RuntimeError):
    pass

def run(command, *, env=None, capture=False):
    command = [str(part) for part in command]
    if not capture:
        print("+ " + " ".join(command), flush=True)
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE if capture else None, stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        raise AndroidError(f"Command failed ({result.returncode}): {command[0]}\n{result.stderr or ''}")
    return result.stdout if capture else None

def sdk_path(args):
    value = args.android_sdk or os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if value:
        return Path(value).expanduser().resolve()
    candidates = [Path.home()/"Library/Android/sdk", Path.home()/"Android/Sdk"]
    return next((path for path in candidates if path.is_dir()), candidates[0])

def tool(path):
    if not path.is_file():
        raise AndroidError(f"Missing tool: {path}")
    return path

def build_env():
    env = os.environ.copy()
    env.update(ADAENGINE_ANDROID="1", SWAN_RUNTIME_ONLY="1")
    env.pop("ADAENGINE_DISABLE_SWAN", None)
    env.pop("ADAENGINE_HEADLESS", None)
    if not env.get("JAVA_HOME"):
        candidates = [Path("/Applications/Android Studio.app/Contents/jbr/Contents/Home")]
        jdk = next((path for path in candidates if (path/"bin/java").exists()), None)
        if jdk:
            env["JAVA_HOME"] = str(jdk)
            env["PATH"] = str(jdk/"bin") + os.pathsep + env.get("PATH", "")
    return env

def swift_command(args):
    return [args.swift]

def swift_sdk_root(args):
    roots = [Path(args.swift_sdks).expanduser()] if args.swift_sdks else [
        Path.home()/"Library/org.swift.swiftpm/swift-sdks", Path.home()/".swiftpm/swift-sdks", Path.home()/".config/swiftpm/swift-sdks"
    ]
    for root in roots:
        bundle = root/f"{args.swift_sdk}.artifactbundle"/"swift-android"
        if bundle.is_dir():
            return root, bundle
    raise AndroidError(f"Swift SDK {args.swift_sdk} is not installed. See Tools/Android/README.md or pass --swift-sdks.")

def ndk_path(args):
    value=args.ndk or os.environ.get("ANDROID_NDK_HOME") or os.environ.get("ANDROID_NDK_ROOT")
    if value:
        return Path(value).expanduser().resolve()
    raise AndroidError("Set ANDROID_NDK_HOME or pass --ndk. Configure the Swift Android SDK with its setup script first.")

def ndk_host(ndk):
    hosts=list((ndk/"toolchains/llvm/prebuilt").glob("*"))
    if len(hosts)!=1:
        raise AndroidError(f"Cannot locate LLVM tools in {ndk}")
    return hosts[0]

def validate_options(args):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+", args.application_id):
        raise AndroidError("application-id must be a Java-style package name")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", args.product):
        raise AndroidError("product must be a SwiftPM dynamic library product name")
    if args.min_sdk < 29 or args.target_sdk < args.min_sdk:
        raise AndroidError("Native host requires Android API 29+ and target-sdk >= min-sdk")

def validate_webgpu(args, env):
    swan = env.get("ADAENGINE_SWAN_PACKAGE_PATH")
    artifact = env.get("SWAN_LOCAL_DAWN")
    if not swan or not artifact:
        raise AndroidError("Android WebGPU requires ADAENGINE_SWAN_PACKAGE_PATH and SWAN_LOCAL_DAWN. See Tools/Android/README.md.")
    swan = Path(swan).expanduser().resolve()
    if not (swan/"Package.swift").is_file() or Path(artifact).is_absolute():
        raise AndroidError("Use a Swan package path and a SWAN_LOCAL_DAWN path relative to that package.")
    bundle = swan/artifact
    try:
        artifacts = json.loads((bundle/"info.json").read_text())["artifacts"]
        variants = [variant for item in artifacts.values() for variant in item["variants"]]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise AndroidError(f"Invalid Dawn artifact bundle {bundle}: {error}") from error
    for abi in (ABIS if args.abi == "all" else [args.abi]):
        triple = f"{ABIS[abi][0]}-unknown-linux-android{args.min_sdk}"
        if not any(triple in variant.get("supportedTriples", []) and (bundle/variant["path"]).is_file() for variant in variants):
            raise AndroidError(f"Dawn bundle has no library for {triple}. Build that ABI with Swan's Dawn/build_android.py.")
    return bundle

def write_manifest(path, args):
    manifest=ET.Element("manifest", {"package": args.application_id})
    ET.SubElement(manifest,"uses-sdk",{ANDROID+"minSdkVersion":str(args.min_sdk),ANDROID+"targetSdkVersion":str(args.target_sdk)})
    ET.SubElement(manifest,"uses-feature",{ANDROID+"glEsVersion":"0x00030001",ANDROID+"required":"true"})
    ET.SubElement(manifest,"uses-permission",{ANDROID+"name":"android.permission.INTERNET"})
    app=ET.SubElement(manifest,"application",{ANDROID+"label":args.label,ANDROID+"hasCode":"false",ANDROID+"debuggable":str(args.configuration=="debug").lower(),ANDROID+"extractNativeLibs":"true",ANDROID+"theme":"@android:style/Theme.Material.NoActionBar.Fullscreen"})
    activity=ET.SubElement(app,"activity",{ANDROID+"name":ACTIVITY,ANDROID+"exported":"true",ANDROID+"configChanges":"orientation|screenSize|screenLayout|keyboardHidden|uiMode|density",ANDROID+"windowSoftInputMode":"adjustNothing"})
    ET.SubElement(activity,"meta-data",{ANDROID+"name":"android.app.lib_name",ANDROID+"value":args.product})
    intent=ET.SubElement(activity,"intent-filter")
    ET.SubElement(intent,"action",{ANDROID+"name":"android.intent.action.MAIN"})
    ET.SubElement(intent,"category",{ANDROID+"name":"android.intent.category.LAUNCHER"})
    ET.ElementTree(manifest).write(path,encoding="utf-8",xml_declaration=True)

def needed_libraries(library, readelf):
    output=run([readelf,"--dynamic",library],capture=True)
    return re.findall(r"Shared library: \[([^\]]+)\]",output)

def collect_libraries(library, candidates, readelf):
    """Resolve every non-system DT_NEEDED dependency; fail on missing runtimes."""
    paths={path.name:path for directory in candidates if directory.is_dir() for path in directory.glob("*.so")}
    paths[library.name]=library
    result={}
    pending=[library]
    while pending:
        current=pending.pop()
        if current.name in result:
            continue
        result[current.name]=current
        for name in needed_libraries(current,readelf):
            if name in SYSTEM_LIBRARIES:
                continue
            if name not in paths:
                raise AndroidError(f"Missing runtime {name}, required by {current.name}")
            pending.append(paths[name])
    return result

def stage_resources(binaries, assets):
    """Copy complete SwiftPM bundles and write the native extraction manifest."""
    destination=assets/"bundles"
    destination.mkdir(parents=True,exist_ok=True)
    for directory in binaries.iterdir():
        if directory.is_dir() and directory.suffix in {".bundle",".resources"}:
            target=destination/directory.name
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(directory,target)
    files=sorted(path.relative_to(destination).as_posix() for path in destination.rglob("*") if path.is_file() and path!=destination/"manifest.txt")
    if not files:
        raise AndroidError("No SwiftPM resource bundles were built")
    (destination/"manifest.txt").write_text("\n".join(files)+"\n")

def select_swift_sdks(args,bundle):
    # Target-triple IDs select the right architecture/API metadata. Restrict
    # discovery to the selected SDK release when several versions are installed.
    selected_sdks=Path(args.scratch).expanduser().resolve()/"swift-sdks"/args.swift_sdk
    selected_sdks.mkdir(parents=True,exist_ok=True)
    link=selected_sdks/f"{args.swift_sdk}.artifactbundle"
    if link.is_symlink() and link.resolve()!=bundle.parent.resolve():
        link.unlink()
    if not link.exists():
        link.symlink_to(bundle.parent,target_is_directory=True)
    if link.resolve()!=bundle.parent.resolve():
        raise AndroidError(f"Unexpected SDK selection path: {link}")
    return selected_sdks

def build(args):
    validate_options(args)
    env=build_env()
    validate_webgpu(args,env)
    sdk=sdk_path(args)
    tools=sdk/"build-tools"/args.build_tools
    swift_roots,bundle=swift_sdk_root(args)
    ndk=ndk_path(args)
    host=ndk_host(ndk)
    env["ANDROID_NDK_HOME"]=str(ndk)
    version=run(swift_command(args)+["--version"],env=env,capture=True)
    match=re.search(r"Swift version (\d+\.\d+(?:\.\d+)?)",version)
    sdk_version=args.swift_sdk.removeprefix("swift-").removesuffix("-RELEASE_android")
    def normalized(version):
        parts=[int(part) for part in version.split(".")]
        return tuple((parts+[0,0,0])[:3])
    if not match or normalized(match.group(1))!=normalized(sdk_version):
        raise AndroidError(f"Host Swift and Android SDK must match exactly: host={version.strip()}, sdk={args.swift_sdk}")
    output=Path(args.output).expanduser().resolve()
    output.mkdir(parents=True,exist_ok=True)
    selected_sdks=select_swift_sdks(args,bundle)
    staging=output/"staging"
    if staging.exists():
        shutil.rmtree(staging)
    (staging/"lib").mkdir(parents=True)
    assets=staging/"assets"
    scratch=Path(args.scratch).expanduser().resolve()
    abis=list(ABIS) if args.abi=="all" else [args.abi]
    for abi in abis:
        arch,ndk_triple=ABIS[abi]
        triple=f"{arch}-unknown-linux-android{args.min_sdk}"
        command=swift_command(args)+["build","--package-path",args.package,"--scratch-path",scratch,"--swift-sdks-path",selected_sdks,"--swift-sdk",triple,"--build-system","native","--product",args.product,"--configuration",args.configuration,"--jobs",str(args.jobs),"--no-static-swift-stdlib","-Xcc","-include","-Xcc","strings.h"]
        run(command,env=env)
        # --show-bin-path is queried with the same destination and configuration.
        binaries=Path(run(command+["--show-bin-path"],env=env,capture=True).strip())
        library=tool(binaries/f"lib{args.product}.so")
        dependencies=collect_libraries(library,[binaries,bundle/"swift-resources/usr/lib"/f"swift-{arch}"/"android",host/"sysroot/usr/lib"/ndk_triple],tool(host/"bin/llvm-readelf"))
        for name,path in dependencies.items():
            target=staging/"lib"/abi/name
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(path,target)
            # Keep full DWARF in the original build/SDK files for debugging;
            # APK copies do not need hundreds of MiB of embedded debug data.
            run([tool(host/"bin/llvm-strip"),"--strip-debug",target],capture=True)
        stage_resources(binaries,assets)
    manifest=output/"AndroidManifest.xml"
    write_manifest(manifest,args)
    unsigned=output/"unsigned.apk"
    run([tool(tools/"aapt2"),"link","--manifest",manifest,"-I",tool(sdk/"platforms"/f"android-{args.target_sdk}"/"android.jar"),"-A",assets,"--version-code","1","--version-name","0.1", "-o",unsigned],env=env)
    with zipfile.ZipFile(unsigned,"a",compression=zipfile.ZIP_STORED) as apk:
        for path in sorted((staging/"lib").rglob("*.so")):
            apk.write(path,path.relative_to(staging).as_posix())
    aligned=output/"aligned.apk"
    run([tool(tools/"zipalign"),"-P","16","-f","4",unsigned,aligned],env=env)
    key=Path(args.debug_keystore).expanduser().resolve() if args.debug_keystore else output/"debug.keystore"
    key.parent.mkdir(parents=True,exist_ok=True)
    if not key.exists():
        keytool=Path(env["JAVA_HOME"])/"bin/keytool" if env.get("JAVA_HOME") else Path(shutil.which("keytool") or "keytool")
        run([keytool,"-genkeypair","-keystore",key,"-storepass","android","-alias","androiddebugkey","-keypass","android","-dname","CN=AdaEngine Android Debug","-keyalg","RSA","-keysize","2048","-validity","10000"],env=env)
    apk=output/f"{args.product}-{args.configuration}.apk"
    run([tool(tools/"apksigner"),"sign","--ks",key,"--ks-key-alias","androiddebugkey","--ks-pass","pass:android","--key-pass","pass:android","--out",apk,aligned],env=env)
    run([tool(tools/"apksigner"),"verify",apk],env=env)
    run([tool(tools/"zipalign"),"-c","-P","16","4",apk],env=env)
    print(f"APK: {apk}")
    return apk

def adb_command(args):
    command=[str(tool(sdk_path(args)/"platform-tools/adb"))]
    if args.serial:
        return command+["-s",args.serial]
    output=run(command+["devices"],capture=True)
    devices=[line.split()[0] for line in output.splitlines()[1:] if len(line.split())>=2 and line.split()[1]=="device"]
    if len(devices)!=1:
        raise AndroidError(f"Expected one authorized Android device, found {len(devices)}. Use --serial; inspect `android.py devices`.")
    return command+["-s",devices[0]]

def launch(args):
    validate_options(args)
    apk=Path(args.apk).expanduser().resolve() if args.apk else build(args)
    tool(apk)
    adb=adb_command(args)
    run(adb+["shell","am","force-stop",args.application_id])
    run(adb+["install","--no-incremental","-r",apk])
    run(adb+["shell","am","start","-W","-n",f"{args.application_id}/{ACTIVITY}"])
    output=run(adb+["shell","pidof",args.application_id],capture=True).strip()
    if not output:
        raise AndroidError("Activity exited during launch; inspect `adb logcat -s AdaEngine AndroidRuntime DEBUG`.")
    print(f"Running {args.application_id}: PID {output}")

def parser():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command",choices=["doctor","build","run","devices"])
    parser.add_argument("--package",default=str(ROOT))
    parser.add_argument("--product",default="AndroidDemo")
    parser.add_argument("--application-id",default="org.adaengine.android.demo")
    parser.add_argument("--label",default="AdaEngine Android")
    parser.add_argument("--swift",default=os.environ.get("SWIFT_ANDROID_SWIFT","swift"))
    parser.add_argument("--swift-sdk",default=os.environ.get("SWIFT_ANDROID_SDK","swift-6.4.0-RELEASE_android"))
    parser.add_argument("--swift-sdks",default=os.environ.get("SWIFT_ANDROID_SDKS_PATH"))
    parser.add_argument("--ndk")
    parser.add_argument("--android-sdk")
    parser.add_argument("--build-tools",default="36.0.0")
    parser.add_argument("--min-sdk",type=int,default=29)
    parser.add_argument("--target-sdk",type=int,default=36)
    parser.add_argument("--abi",choices=[*ABIS,"all"],default="arm64-v8a")
    parser.add_argument("--configuration",choices=["debug","release"],default="debug")
    parser.add_argument("--scratch",default=os.environ.get("SWIFT_ANDROID_SCRATCH",str(ROOT/".build-android")))
    parser.add_argument("--output",default=str(ROOT/".build-android/apk"))
    parser.add_argument("--debug-keystore",help="Stable development signing key for rebuild/install updates")
    parser.add_argument("--jobs",type=int,default=6)
    parser.add_argument("--serial")
    parser.add_argument("--apk",help="Install an existing APK without rebuilding")
    return parser

def main():
    args=parser().parse_args()
    try:
        if args.command=="build": build(args)
        elif args.command=="run": launch(args)
        elif args.command=="devices": run([tool(sdk_path(args)/"platform-tools/adb"),"devices","-l"])
        else:
            validate_options(args)
            env=build_env()
            print("Dawn WebGPU:",validate_webgpu(args,env))
            print(run(swift_command(args)+["--version"],env=env,capture=True).strip())
            print("Swift SDK:",swift_sdk_root(args)[1])
            print("NDK:",ndk_host(ndk_path(args)))
            sdk=sdk_path(args)
            for name in ["aapt2","zipalign","apksigner"]: print("Tool:",tool(sdk/"build-tools"/args.build_tools/name))
            print("Android platform:",tool(sdk/"platforms"/f"android-{args.target_sdk}"/"android.jar"))
            run([tool(sdk/"platform-tools/adb"),"devices","-l"])
    except (AndroidError,OSError) as error:
        print(f"error: {error}",file=sys.stderr)
        return 1
    return 0

if __name__=="__main__":
    sys.exit(main())
