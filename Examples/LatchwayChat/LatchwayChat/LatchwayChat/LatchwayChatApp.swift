//
//  LatchwayChatApp.swift
//  LatchwayChat
//
//  Created by Peter Vu on 5/9/26.
//

import SwiftUI
import FirebaseCore

@main
struct LatchwayChatApp: App {
    init() {
        FirebaseConfiguration.shared.setLoggerLevel(.error)
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
