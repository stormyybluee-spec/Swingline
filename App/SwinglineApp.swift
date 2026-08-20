//
//  SwinglineApp.swift
//  Swingline
//
//  The app entry point. This did not exist in any earlier pass, because the
//  files handed over so far were views and engine, never the thing that mounts
//  them. Without an @main the project builds a bundle with no way to launch,
//  so this is the one genuinely new file in this delivery.
//
//  RootView owns everything: its own navigation stack, the AppStore it creates,
//  the tab bar, the ambient background. So this file does nothing except hand
//  the window to RootView. That is deliberate. An entry point that starts
//  making decisions about state or routing is an entry point that fights the
//  store it is supposed to defer to.
//
//  House rule: no em dashes anywhere.
//

import SwiftUI

@main
struct SwinglineApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
