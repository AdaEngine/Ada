# Known issues and how to debug SPM targets

## Xcode Instruments: "Required kernel recording resources are in use by another document"

When profiling an SPM project (without an xcodeproj) in Instruments, you may see a message about kernel recording resources being in use, even when no other Instruments documents are open.

**Cause:** The message is misleading. The real cause is that the binary does not have the `get-task-allow` entitlement. SPM does not distinguish between “release” and “profiling,” so profiling uses a release build without this entitlement.

**Solution:** Re-sign the binary with the `get-task-allow` entitlement before launching Instruments.

1. Open your scheme (Cmd-Shift-,).
2. In **Profile → Pre-actions**, add a Pre-action.
3. Set the shell to `/bin/zsh`.
4. Paste the re-sign script below (the `=(...)` syntax is zsh process substitution):

```zsh
# For Instruments, re-sign binary with get-task-allow entitlement
codesign -s - -v -f --entitlements =(echo -n '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>com.apple.security.get-task-allow</key>
        <true/>
    </dict>
</plist>') ${TARGET_BUILD_DIR}/${PRODUCT_NAME}
```

See also: [Solving "Required kernel recording resources..." in Instruments](https://cocoaphony.micro.blog/2022/10/29/solving-required-kernel.html) (Rob Napier).

The script is stored in `.swiftpm/xcode/xcshareddata/xcschemes/<schemename>.xcscheme`. The pre-action runs only for Profile, so it does not affect normal builds.

**Note:** Pre-action scripts do not receive `SRCROOT`; if the script fails, Xcode will not show details—check Console.app for logs.
