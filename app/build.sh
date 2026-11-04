#!/bin/bash
# Build TimeWallpaper.app from source (macOS 13+, Apple Silicon or Intel)
set -e
cd "$(dirname "$0")"
APP="TimeWallpaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/TimeWallpaper" main.swift -framework Cocoa
codesign --force --deep -s - "$APP"
echo "built: $(pwd)/$APP"
echo "run:   open $APP"
