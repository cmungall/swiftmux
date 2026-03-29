# Build the app
build:
    swift build

# Run tests
test:
    swift test

# Build and create .app bundle
app: build
    #!/bin/bash
    mkdir -p SwiftMux.app/Contents/MacOS
    cp .build/debug/SwiftMux SwiftMux.app/Contents/MacOS/
    cat > SwiftMux.app/Contents/Info.plist << 'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleExecutable</key>
        <string>SwiftMux</string>
        <key>CFBundleIdentifier</key>
        <string>dev.mungall.SwiftMux</string>
        <key>CFBundleName</key>
        <string>SwiftMux</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleVersion</key>
        <string>0.1</string>
        <key>LSMinimumSystemVersion</key>
        <string>13.0</string>
        <key>NSHighResolutionCapable</key>
        <true/>
    </dict>
    </plist>
    PLIST
    echo "SwiftMux.app built"

# Build and open
run: app
    open SwiftMux.app

# Clean build artifacts
clean:
    swift package clean
    rm -rf SwiftMux.app
