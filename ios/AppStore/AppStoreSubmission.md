# GymTracker App Store Submission Pack

Last updated: March 30, 2026

## Repo Deliverables Included

- Privacy policy draft: [`/Users/calebmorton/home-gym-tracker/ios/AppStore/PrivacyPolicy.md`](/Users/calebmorton/home-gym-tracker/ios/AppStore/PrivacyPolicy.md)
- iOS bundle display name aligned to `GymTracker`
- HealthKit usage descriptions aligned to current app behavior
- Stale `armv7` required-device capability removed

## App Store Connect Metadata Draft

App Name:
`GymTracker`

Subtitle:
`Track workouts, food, and progress`

Category:
`Health & Fitness`

Promotional Text:
`Log lifting sessions, food, and body weight in one place with built-in progression tools and Apple Health sync.`

Keywords:
`gym,workout,fitness,nutrition,macros,bodyweight,healthkit,strength,training`

Description:
`GymTracker helps lifters track training, nutrition, and body-weight progress without juggling separate apps. Build multi-day workout plans, log sets with plate math and rest timers, scan foods by barcode or label, and monitor estimated one-rep max trends over time. If Apple Health access is enabled, GymTracker can read body-weight data and write completed workouts and body-weight entries to keep your health data in sync.`

## Screenshot Plan

Prepare at least one complete screenshot set for the required iPhone sizes in App Store Connect.

Recommended sequence:

1. Dashboard showing next workout, recent progress, and nutrition summary
2. Active workout screen with set logging and plate math
3. Nutrition logging screen with barcode or OCR flow
4. Body-weight or progress chart screen
5. Settings or Apple Health connection screen

## App Privacy / Review Notes Draft

Use this reviewer note:

`GymTracker is a workout and nutrition tracker. HealthKit access is optional. When permission is granted, the app reads body weight and body fat percentage, and writes completed workouts and body-weight entries. HealthKit data is used only for user-facing fitness tracking features and not for advertising or profiling.`

## Manual Steps Still Required

These steps cannot be completed from the repo alone:

1. Publish the privacy policy at a public HTTPS URL and use that URL in App Store Connect.
2. Confirm Apple Developer Program membership is active for the submission account.
3. Create or update the App Store Connect app record.
4. Upload screenshots for the required iPhone sizes.
5. Fill in support URL, marketing URL if used, privacy nutrition answers, and age rating.
6. Archive and upload the signed build from Xcode or Transporter.
7. Submit the build for App Review.

## Pre-Submission Verification

Before upload, verify:

1. HealthKit capability is enabled in the target entitlements.
2. HealthKit permission strings match actual read/write behavior.
3. The displayed app name is `GymTracker`.
4. A production support contact is available in the privacy policy and App Store listing.
5. The final build runs on a current iPhone simulator/device without debug-only behavior.
