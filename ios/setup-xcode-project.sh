#!/bin/bash
# Creates the native GymTracker Xcode project
# Run: cd ios && ./setup-xcode-project.sh

set -e

echo "=== GymTracker Native iOS Setup ==="
echo ""
echo "The Swift source files are already in ios/GymTracker/Sources/"
echo ""
echo "To create the Xcode project:"
echo ""
echo "1. Open Xcode"
echo "2. File → New → Project"
echo "3. iOS → App"
echo "4. Product Name: GymTracker"
echo "5. Team: (your team)"
echo "6. Organization Identifier: dev.lethal"
echo "7. Interface: SwiftUI"
echo "8. Language: Swift"
echo "9. Storage: None"
echo "10. SAVE THE PROJECT IN: $(pwd)/GymTracker/"
echo "    (overwrite the existing folder)"
echo ""
echo "11. After creation, delete the auto-generated ContentView.swift and GymTrackerApp.swift"
echo "12. Add existing files: select all .swift files from Sources/ subfolders"
echo "13. Add HealthKit capability: target → Signing & Capabilities → + → HealthKit"
echo ""
echo "Then build and run (Cmd+R) on your iPhone."
