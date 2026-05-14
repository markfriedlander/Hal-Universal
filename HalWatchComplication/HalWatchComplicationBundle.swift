//
//  HalWatchComplicationBundle.swift
//  Hal Universal Watch Complication
//
//  Entry point for the WidgetKit extension that backs Hal's watchOS
//  complication. Lists every Widget the extension declares — currently
//  just one (HalWatchComplication, a minimal launcher).
//
//  This file is part of the Pre-ship #1D autonomous prep work. The source
//  files here will only build once a WidgetKit Extension target is added
//  to the Xcode project (File → New → Target → Widget Extension, named
//  "HalWatchComplication", configured for watchOS). That target work is
//  deferred to the hardware session because the pbxproj target UUIDs and
//  the build-phase wiring don't hand-edit safely from text — Xcode's
//  wizard is the safe path.
//
//  Created by Claude Code on 2026-05-14.
//

import SwiftUI
import WidgetKit

@main
struct HalWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        HalWatchComplication()
    }
}
