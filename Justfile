# Build the app and bundled server
build:
    #!/bin/bash
    set -euo pipefail
    source "$HOME/.swiftly/env.sh"
    export DEVELOPER_DIR="${SWIFTMUX_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
    export CLANG_MODULE_CACHE_PATH=/tmp/swiftmux-clang-module-cache
    export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftmux-clang-module-cache
    swift build --disable-sandbox --product SwiftMux
    swift build --disable-sandbox --product SwiftMuxServer

# Run tests, or compile the full package when no tests exist
test:
    #!/bin/bash
    set -euo pipefail
    source "$HOME/.swiftly/env.sh"
    export DEVELOPER_DIR="${SWIFTMUX_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
    export CLANG_MODULE_CACHE_PATH=/tmp/swiftmux-clang-module-cache
    export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftmux-clang-module-cache
    if [ -d Tests ] && find Tests -name '*.swift' -print -quit | grep -q .; then
        swift test
    else
        swift build --disable-sandbox
    fi

# Build and create .app bundle
app: build
    #!/bin/bash
    set -euo pipefail
    rm -rf SwiftMux.app
    mkdir -p SwiftMux.app/Contents/MacOS
    mkdir -p SwiftMux.app/Contents/Resources
    cp .build/debug/SwiftMux SwiftMux.app/Contents/MacOS/
    cp .build/debug/SwiftMuxServer SwiftMux.app/Contents/MacOS/
    cp Sources/SwiftMux/Resources/SwiftMux.icns SwiftMux.app/Contents/Resources/
    cp -R Web SwiftMux.app/Contents/Resources/
    actool_log="$(mktemp /tmp/swiftmux-actool.XXXXXX.log)"
    if ! DEVELOPER_DIR="${SWIFTMUX_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        xcrun actool Sources/SwiftMux/Resources/Assets.xcassets \
        --compile SwiftMux.app/Contents/Resources \
        --platform macosx \
        --target-device mac \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /tmp/swiftmux-assets-partial.plist \
        >/dev/null 2>"$actool_log"; then
        cat "$actool_log" >&2
        rm -f "$actool_log"
        exit 1
    fi
    rm -f "$actool_log"
    xml_escape() {
        printf '%s' "$1" | sed \
            -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g' \
            -e 's/"/\&quot;/g' \
            -e "s/'/\&apos;/g"
    }
    git_commit="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
    git_commit="${git_commit:-unknown}"
    git_branch="$(git branch --show-current 2>/dev/null || true)"
    git_dirty="false"
    if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
        git_dirty="true"
    fi
    app_version="$(xml_escape "${SWIFTMUX_VERSION:-dev}")"
    git_commit="$(xml_escape "$git_commit")"
    git_branch="$(xml_escape "$git_branch")"
    git_dirty="$(xml_escape "$git_dirty")"
    cat > SwiftMux.app/Contents/Info.plist << PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleExecutable</key>
        <string>SwiftMux</string>
        <key>CFBundleIdentifier</key>
        <string>dev.mungall.SwiftMux</string>
        <key>CFBundleIconName</key>
        <string>AppIcon</string>
        <key>CFBundleName</key>
        <string>SwiftMux</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>$app_version</string>
        <key>CFBundleVersion</key>
        <string>1</string>
        <key>LSMinimumSystemVersion</key>
        <string>14.0</string>
        <key>NSHighResolutionCapable</key>
        <true/>
        <key>SwiftMuxGitBranch</key>
        <string>$git_branch</string>
        <key>SwiftMuxGitCommit</key>
        <string>$git_commit</string>
        <key>SwiftMuxGitDirty</key>
        <string>$git_dirty</string>
    </dict>
    </plist>
    PLIST
    echo "SwiftMux.app built"

# Build and open
run: app
    open SwiftMux.app

# Build side-by-side test .app bundle
app-test: build
    #!/bin/bash
    set -euo pipefail
    app_bundle="SwiftMux Test.app"
    bundle_name="SwiftMux Test"
    bundle_identifier="dev.mungall.SwiftMux.Test"
    rm -rf "$app_bundle"
    mkdir -p "$app_bundle/Contents/MacOS"
    mkdir -p "$app_bundle/Contents/Resources"
    cp .build/debug/SwiftMux "$app_bundle/Contents/MacOS/"
    cp .build/debug/SwiftMuxServer "$app_bundle/Contents/MacOS/"
    cp Sources/SwiftMux/Resources/SwiftMux.icns "$app_bundle/Contents/Resources/"
    cp -R Web "$app_bundle/Contents/Resources/"
    actool_log="$(mktemp /tmp/swiftmux-actool.XXXXXX.log)"
    if ! DEVELOPER_DIR="${SWIFTMUX_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
        xcrun actool Sources/SwiftMux/Resources/Assets.xcassets \
        --compile "$app_bundle/Contents/Resources" \
        --platform macosx \
        --target-device mac \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /tmp/swiftmux-assets-partial.plist \
        >/dev/null 2>"$actool_log"; then
        cat "$actool_log" >&2
        rm -f "$actool_log"
        exit 1
    fi
    rm -f "$actool_log"
    xml_escape() {
        printf '%s' "$1" | sed \
            -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g' \
            -e 's/"/\&quot;/g' \
            -e "s/'/\&apos;/g"
    }
    git_commit="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
    git_commit="${git_commit:-unknown}"
    git_branch="$(git branch --show-current 2>/dev/null || true)"
    git_dirty="false"
    if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
        git_dirty="true"
    fi
    app_version="$(xml_escape "${SWIFTMUX_VERSION:-dev}")"
    git_commit="$(xml_escape "$git_commit")"
    git_branch="$(xml_escape "$git_branch")"
    git_dirty="$(xml_escape "$git_dirty")"
    bundle_name="$(xml_escape "$bundle_name")"
    bundle_identifier="$(xml_escape "$bundle_identifier")"
    cat > "$app_bundle/Contents/Info.plist" << PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleExecutable</key>
        <string>SwiftMux</string>
        <key>CFBundleIdentifier</key>
        <string>$bundle_identifier</string>
        <key>CFBundleIconName</key>
        <string>AppIcon</string>
        <key>CFBundleName</key>
        <string>$bundle_name</string>
        <key>CFBundleDisplayName</key>
        <string>$bundle_name</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>$app_version</string>
        <key>CFBundleVersion</key>
        <string>1</string>
        <key>LSMinimumSystemVersion</key>
        <string>14.0</string>
        <key>NSHighResolutionCapable</key>
        <true/>
        <key>SwiftMuxGitBranch</key>
        <string>$git_branch</string>
        <key>SwiftMuxGitCommit</key>
        <string>$git_commit</string>
        <key>SwiftMuxGitDirty</key>
        <string>$git_dirty</string>
    </dict>
    </plist>
    PLIST
    echo "$app_bundle built"

# Build and open side-by-side test app
run-test: app-test
    open -n "SwiftMux Test.app"

# Clean build artifacts
clean:
    swift package clean
    rm -rf SwiftMux.app "SwiftMux Test.app"
