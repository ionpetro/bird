#!/bin/bash
set -e
swift build 2>&1
codesign --force --sign - --entitlements bird-dev.entitlements .build/arm64-apple-macosx/debug/bird
.build/arm64-apple-macosx/debug/bird
