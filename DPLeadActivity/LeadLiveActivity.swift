//
//  LeadLiveActivity.swift
//  DPLeadActivity
//
//  The card for a new quote request or contact message: Lock Screen, Dynamic Island,
//  and (mirrored by watchOS) the Apple Watch Smart Stack.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct LeadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LeadActivityAttributes.self) { context in
            LeadCard(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Badge(kind: context.state.kind) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(Self.time(context.state.receivedAt)).font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.headline).lineLimit(1)
                        Text(context.state.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Logo(size: 20)
            } compactTrailing: {
                Image(systemName: Self.symbol(context.state.kind)).foregroundStyle(.orange)
            } minimal: {
                Image(systemName: Self.symbol(context.state.kind)).foregroundStyle(.orange)
            }
        }
        .supplementalActivityFamilies([.small, .medium]) // Apple Watch Smart Stack
    }

    static func symbol(_ kind: String) -> String { kind == "quote" ? "doc.text.fill" : "person.crop.circle.badge.plus" }
    static func label(_ kind: String) -> String { kind == "quote" ? "New Quote Request" : "New Web Prospect" }
    static func time(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
    }
}

/// The DP logo (a 120 px copy: Live Activities only render small images).
private struct Logo: View {
    let size: CGFloat
    var body: some View {
        Image("DPLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityLabel("DP Consulting")
    }
}

private struct Badge: View {
    let kind: String
    var body: some View {
        HStack(spacing: 6) {
            Logo(size: 24)
            Image(systemName: LeadLiveActivity.symbol(kind)).foregroundStyle(.orange)
        }
    }
}

private struct LeadCard: View {
    @Environment(\.activityFamily) private var family
    let state: LeadActivityAttributes.ContentState

    var body: some View {
        if family == .small {
            // Watch Smart Stack and other small spots: say what it is and who.
            HStack(alignment: .top, spacing: 8) {
                Logo(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LeadLiveActivity.label(state.kind))
                        .font(.caption.bold()).foregroundStyle(.orange).lineLimit(1)
                    Text(state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(state.detail).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        } else {
            HStack(alignment: .top, spacing: 12) {
                Logo(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(LeadLiveActivity.label(state.kind)).font(.caption.bold()).foregroundStyle(.orange)
                        Spacer()
                        Text(LeadLiveActivity.time(state.receivedAt)).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Text(state.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(state.detail).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                }
            }
            .padding(14)
        }
    }
}
