#!/usr/bin/env bash
# Build and install standalone Ada Studio, or copy an existing application bundle.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: bash script/install_studio_macos.sh [options]
  --source PATH        Install an existing .app instead of building
  --destination PATH   Applications directory (default: /Applications)
  --derived-data PATH  Xcode build cache (default: Editor/.build/install-xcode)
  --launch             Open the installed application
  --help               Show this help

Without --source, requires Xcode, XcodeGen and the repository's build dependencies.
For a per-user install, use --destination "$HOME/Applications".
USAGE
}

fail() { echo "error: $*" >&2; exit 1; }
studio_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
studio_source=""
studio_applications="/Applications"
studio_derived_data="$studio_root/Editor/.build/install-xcode"
studio_launch=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source|--destination|--derived-data)
            [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
            case "$1" in
                --source) studio_source="$2" ;;
                --destination) studio_applications="$2" ;;
                --derived-data) studio_derived_data="$2" ;;
            esac
            shift 2 ;;
        --launch) studio_launch=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)" ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || fail 'This installer requires macOS.'

validate_app() {
    local bundle="$1" executable identifier
    [[ -f "$bundle/Contents/Info.plist" ]] || fail "Missing Info.plist in $bundle"
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")"
    [[ "$identifier" == org.adaengine.editor || "$identifier" == org.adaengine.studio.dev ]] || fail "Not an Ada Studio application: $bundle"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
    [[ -n "$executable" && "$executable" != */* && -x "$bundle/Contents/MacOS/$executable" ]] || fail "Missing app executable in $bundle"
}

if [[ -z "$studio_source" ]]; then
    command -v xcodegen >/dev/null || fail 'XcodeGen is required to build Studio.'
    command -v xcodebuild >/dev/null || fail 'Xcode is required to build Studio.'
    mkdir -p "$studio_derived_data"
    studio_derived_data="$(cd "$studio_derived_data" && pwd -P)"
    xcodegen generate --spec "$studio_root/Editor/project.yml"
    xcodebuild -project "$studio_root/Editor/AdaEditor.xcodeproj" \
        -scheme AdaEditor-Standalone -configuration Release -destination 'platform=macOS' \
        -derivedDataPath "$studio_derived_data" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    studio_source="$studio_derived_data/Build/Products/Release/Ada Studio.app"
    # Local source builds use an ad-hoc signature; prebuilt bundles keep their signatures.
    /usr/bin/codesign --force --deep --sign - \
        --entitlements "$studio_root/Editor/Platforms/AdaEditor-Standalone.entitlements" "$studio_source"
    /usr/bin/codesign --verify --deep --strict "$studio_source"
fi
[[ -d "$studio_source" ]] || fail "Application bundle not found: $studio_source"
studio_source="$(cd "$studio_source" && pwd -P)"
validate_app "$studio_source"
mkdir -p "$studio_applications" || fail 'Cannot create destination. Choose a writable --destination or run with appropriate permissions.'
studio_applications="$(cd "$studio_applications" && pwd -P)"
studio_destination="$studio_applications/Ada Studio.app"
case "$studio_source/" in "$studio_destination/"*) fail 'Source and destination must be separate, non-overlapping directories.' ;; esac
case "$studio_destination/" in "$studio_source/"*) fail 'Source and destination must be separate, non-overlapping directories.' ;; esac
[[ ! -L "$studio_destination" ]] || fail 'The installed application must not be a symbolic link.'
if [[ -e "$studio_destination" ]]; then validate_app "$studio_destination"; fi
while IFS= read -r studio_command; do
    case "$studio_command" in
        "$studio_destination/Contents/MacOS/"*) fail 'Close Ada Studio and its command-line tools before updating this installation.' ;;
    esac
done < <(ps -axo comm=)

studio_temporary="$(mktemp -d "$studio_applications/.ada-studio-install.XXXXXX")" || fail 'Destination is not writable. Try --destination "$HOME/Applications".'
studio_staged="$studio_temporary/Ada Studio.app"
studio_backup="$studio_temporary/previous.app"
cleanup() {
    if [[ -d "$studio_backup" && ! -e "$studio_destination" ]]; then
        mv "$studio_backup" "$studio_destination" || { echo "Previous installation preserved at $studio_backup" >&2; return; }
    fi
    if [[ -d "$studio_backup" ]]; then
        echo "Previous installation preserved at $studio_backup" >&2
    else
        rm -rf -- "$studio_temporary"
    fi
}
trap cleanup EXIT
/usr/bin/ditto "$studio_source" "$studio_staged"
validate_app "$studio_staged"
if [[ -e "$studio_destination" ]]; then mv "$studio_destination" "$studio_backup"; fi
mv "$studio_staged" "$studio_destination"
if [[ -d "$studio_backup" ]]; then rm -rf -- "$studio_backup"; fi

studio_register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
if [[ -x "$studio_register" ]]; then "$studio_register" -f "$studio_destination" || true; fi
echo "Installed Ada Studio: $studio_destination"
if [[ "$studio_launch" == 1 ]]; then /usr/bin/open "$studio_destination"; fi
