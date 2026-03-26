//
//  GymTrackerWatch.swift
//  GymTrackerWatch
//
//  Created by c on 3/26/26.
//

import AppIntents

struct GymTrackerWatch: AppIntent {
    static var title: LocalizedStringResource { "GymTrackerWatch" }
    
    func perform() async throws -> some IntentResult {
        return .result()
    }
}
