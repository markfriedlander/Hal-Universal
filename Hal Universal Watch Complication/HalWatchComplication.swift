//
//  HalWatchComplication.swift
//  Hal Universal Watch Complication
//
//  Minimal launcher complication for Hal on watchOS. Strategic Claude's
//  May-14 spec: ".accessoryCircular at minimum, default tap-to-launch
//  behavior, single static TimelineProvider entry." No live data — the
//  complication is essentially a glanceable shortcut to open the Watch
//  app from any watchface.
//
//  Design choices:
//  - Single TimelineEntry, no refresh policy beyond .never. The icon
//    doesn't change unless the bundle ships an update.
//  - .accessoryCircular shown initially. .accessoryRectangular and
//    .accessoryInline added below for users who pin Hal to those slots
//    on their watchface — they cost almost nothing once the entry
//    timeline is in place.
//  - Tap-to-launch is the default WidgetKit behavior when no
//    `widgetURL(...)` is set. Left at the default so a future deep-link
//    architecture can be added cleanly.
//  - The icon assumes `Image("HalEye")` is in the extension's asset
//    catalog. When wiring the target in Xcode, copy
//    `Hal Universal Watch/Assets.xcassets/HalEye.imageset` to the new
//    extension target (or add a "Membership" checkbox to the existing
//    asset catalog so both targets share it). If the asset can't be
//    found, the SF Symbol fallback (`brain.head.profile.fill`) renders
//    instead — useful for the smoke build pre-asset-wiring.
//
//  Created by Claude Code on 2026-05-14.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline entry

struct HalLauncherEntry: TimelineEntry {
    let date: Date
}

// MARK: - Timeline provider

struct HalLauncherProvider: TimelineProvider {

    func placeholder(in context: Context) -> HalLauncherEntry {
        HalLauncherEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (HalLauncherEntry) -> Void) {
        completion(HalLauncherEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HalLauncherEntry>) -> Void) {
        // One entry, never refresh. The complication is a static launcher;
        // there's no live data to keep current.
        let timeline = Timeline(entries: [HalLauncherEntry(date: Date())], policy: .never)
        completion(timeline)
    }
}

// MARK: - Entry view

struct HalLauncherEntryView: View {
    var entry: HalLauncherProvider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularBody
            case .accessoryRectangular:
                rectangularBody
            case .accessoryInline:
                inlineBody
            default:
                circularBody  // safe fallback for any future family
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // accessoryCircular — the headline launcher. Fills the small round slot
    // with the HalEye image (or SF Symbol fallback). Tap defaults to launch.
    private var circularBody: some View {
        ZStack {
            // Image asset preferred; if not in the extension's catalog the
            // missing-image fallback resolves to nothing, so we layer the
            // SF Symbol underneath as a guaranteed-visible safety net.
            Image(systemName: "brain.head.profile.fill")
                .resizable()
                .scaledToFit()
                .padding(6)
                .foregroundStyle(.primary)
            Image("HalEye")
                .resizable()
                .scaledToFit()
                .padding(4)
        }
    }

    // accessoryRectangular — name + tagline (no live data).
    private var rectangularBody: some View {
        HStack(spacing: 6) {
            Image("HalEye")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hal").font(.headline)
                Text("Tap to talk").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    // accessoryInline — single-line label only. SF Symbol is more reliable
    // than an asset image at inline density.
    private var inlineBody: some View {
        Label("Hal", systemImage: "brain.head.profile.fill")
    }
}

// MARK: - Widget definition

struct HalWatchComplication: Widget {
    let kind: String = "com.MarkFriedlander.Hal-Universal.WatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HalLauncherProvider()) { entry in
            HalLauncherEntryView(entry: entry)
        }
        .configurationDisplayName("Hal")
        .description("Tap to open Hal on your wrist.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// MARK: - Previews

#Preview("Circular", as: .accessoryCircular) {
    HalWatchComplication()
} timeline: {
    HalLauncherEntry(date: Date())
}

#Preview("Rectangular", as: .accessoryRectangular) {
    HalWatchComplication()
} timeline: {
    HalLauncherEntry(date: Date())
}

#Preview("Inline", as: .accessoryInline) {
    HalWatchComplication()
} timeline: {
    HalLauncherEntry(date: Date())
}
