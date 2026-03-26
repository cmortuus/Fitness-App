#!/usr/bin/env bash
# Build and open the iOS project in Xcode for sideloading
set -euo pipefail

echo "=== GymTracker iOS Build ==="
echo ""
echo "This builds the Capacitor iOS project and opens it in Xcode."
echo "From Xcode, connect your iPhone and click Run to sideload."
echo ""

cd "$(dirname "$0")/frontend"

# Ensure dist dir exists (Capacitor needs it even when using server URL)
mkdir -p dist
echo '<!DOCTYPE html><html><body>Loading GymTracker...</body></html>' > dist/index.html

# Sync Capacitor config to the iOS project
npx cap sync ios

echo ""
echo "Opening Xcode..."
echo ""
echo "In Xcode:"
echo "  1. Select your iPhone as the target device"
echo "  2. Go to Signing & Capabilities → select your Apple ID team"
echo "  3. Click the Run button (▶)"
echo "  4. Trust the developer on your iPhone: Settings → General → VPN & Device Management"
echo ""

npx cap open ios
