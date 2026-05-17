# Build the app
build:
    DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH=/tmp/swiftmux-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftmux-clang-module-cache swift build --disable-sandbox --product SwiftMux
    DEVELOPER_DIR=/Library/Developer/CommandLineTools CLANG_MODULE_CACHE_PATH=/tmp/swiftmux-clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftmux-clang-module-cache swift build --disable-sandbox --product SwiftMuxServer

# Run tests
test:
    DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test

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
    xcrun actool Sources/SwiftMux/Resources/Assets.xcassets \
        --compile SwiftMux.app/Contents/Resources \
        --platform macosx \
        --target-device mac \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /tmp/swiftmux-assets-partial.plist \
        >/dev/null 2>/tmp/swiftmux-actool.log || { cat /tmp/swiftmux-actool.log >&2; exit 1; }
    cat > SwiftMux.app/Contents/Info.plist << 'PLIST'
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
        <key>CFBundleVersion</key>
        <string>0.1</string>
        <key>LSMinimumSystemVersion</key>
        <string>14.0</string>
        <key>NSHighResolutionCapable</key>
        <true/>
    </dict>
    </plist>
    PLIST
    echo "SwiftMux.app built"

# Build and create a side-by-side dev .app bundle
dev-app: build
    #!/bin/bash
    set -euo pipefail
    rm -rf "SwiftMux Dev.app"
    mkdir -p "SwiftMux Dev.app/Contents/MacOS"
    mkdir -p "SwiftMux Dev.app/Contents/Resources"
    cp .build/debug/SwiftMux "SwiftMux Dev.app/Contents/MacOS/"
    cp .build/debug/SwiftMuxServer "SwiftMux Dev.app/Contents/MacOS/"
    cp Sources/SwiftMux/Resources/SwiftMux.icns "SwiftMux Dev.app/Contents/Resources/"
    cp -R Web "SwiftMux Dev.app/Contents/Resources/"
    xcrun actool Sources/SwiftMux/Resources/Assets.xcassets \
        --compile "SwiftMux Dev.app/Contents/Resources" \
        --platform macosx \
        --target-device mac \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /tmp/swiftmux-dev-assets-partial.plist \
        >/dev/null 2>/tmp/swiftmux-dev-actool.log || { cat /tmp/swiftmux-dev-actool.log >&2; exit 1; }
    cat > "SwiftMux Dev.app/Contents/Info.plist" << 'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleExecutable</key>
        <string>SwiftMux</string>
        <key>CFBundleIdentifier</key>
        <string>dev.mungall.SwiftMux.dev</string>
        <key>CFBundleIconName</key>
        <string>AppIcon</string>
        <key>CFBundleName</key>
        <string>SwiftMux Dev</string>
        <key>CFBundleDisplayName</key>
        <string>SwiftMux Dev</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleVersion</key>
        <string>0.1-dev</string>
        <key>LSMinimumSystemVersion</key>
        <string>14.0</string>
        <key>NSHighResolutionCapable</key>
        <true/>
    </dict>
    </plist>
    PLIST
    echo "SwiftMux Dev.app built"

# Build and open
run: app
    open SwiftMux.app

# Build and open the side-by-side dev app from this worktree
dev-run: dev-app
    open -n "SwiftMux Dev.app"

# Clean build artifacts
clean:
    swift package clean
    rm -rf SwiftMux.app "SwiftMux Dev.app"
