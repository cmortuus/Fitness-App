import Foundation
import SwiftUI
import UIKit
import os

// MARK: - App Logger

let appLog = Logger(subsystem: "dev.lethal.gymtracker", category: "app")

// MARK: - App Constants

enum AppConstants {
    static let plateTolerance: Double = 0.1
    static let estimatedSecondsPerSet: Double = 40.0
    static let settingsSyncDebounceMs: UInt64 = 500
    static let searchDebounceMs: UInt64 = 300
    static let defaultBarWeightLbs: Double = 45.0
    static let defaultBarWeightKg: Double = 20.0
    static let minTapTarget: CGFloat = 44.0
    static let cardCornerRadius: CGFloat = 16.0  // matches web rounded-2xl
    static let darkCardBackground = Color(white: 0.11)
}

// MARK: - Design System (matching web Tailwind zinc palette)

enum AppColors {
    // Zinc palette — matches Tailwind zinc scale
    static let zinc950 = Color(red: 0.055, green: 0.055, blue: 0.063)  // bg
    static let zinc900 = Color(red: 0.094, green: 0.094, blue: 0.106)  // card
    static let zinc800 = Color(red: 0.153, green: 0.153, blue: 0.169)  // card-elevated, inputs
    static let zinc700 = Color(red: 0.247, green: 0.247, blue: 0.267)  // borders
    static let zinc600 = Color(red: 0.329, green: 0.329, blue: 0.353)  // input borders
    static let zinc500 = Color(red: 0.443, green: 0.443, blue: 0.471)  // muted text
    static let zinc400 = Color(red: 0.631, green: 0.631, blue: 0.659)  // secondary text
    static let zinc300 = Color(red: 0.831, green: 0.831, blue: 0.847)  // primary text
    static let zinc100 = Color(red: 0.953, green: 0.953, blue: 0.961)  // bright text

    // Accent colors
    static let primary = Color(red: 0.231, green: 0.510, blue: 0.965)  // #3b82f6
    static let accent = Color(red: 0.545, green: 0.361, blue: 0.965)   // #8b5cf6
}

extension View {
    /// Standard card style — matches web `.card` class (zinc-900, rounded-2xl, 1px zinc-800 border)
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(AppColors.zinc900)
            .clipShape(RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius)
                    .strokeBorder(AppColors.zinc800, lineWidth: 1)
            )
    }

    /// Elevated card style — matches web `.card-elevated` (zinc-800, shadow)
    func cardElevatedStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(AppColors.zinc800)
            .clipShape(RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius)
                    .strokeBorder(AppColors.zinc700, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    /// Input field style — matches web `.set-input` (zinc-800, zinc-600 border, rounded-lg)
    func inputStyle() -> some View {
        self
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(height: 48)
            .background(AppColors.zinc800)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(AppColors.zinc600, lineWidth: 1)
            )
    }
}


// MARK: - Keyboard Utilities

/// Dismiss the software keyboard from anywhere
func hideKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
}

extension View {
    /// Adds a "Done" button in a toolbar above number/decimal pads
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
                    .fontWeight(.semibold)
            }
        }
    }

    /// Dismiss keyboard when tapping outside text fields
    func dismissKeyboardOnTap() -> some View {
        simultaneousGesture(
            TapGesture().onEnded { hideKeyboard() }
        )
    }
}

extension Collection {
    /// Safe subscript — returns nil instead of crashing on out-of-bounds
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
