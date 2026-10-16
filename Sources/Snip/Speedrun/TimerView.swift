import SwiftUI

/// LiveSplit's default look, which speedrunners expect: dark gradient, title, splits with the blue
/// current-split bar, the big two-size timer, and Previous Segment. Colours are LiveSplit's defaults.
enum SplitColors {
    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }

    static let backgroundTop = rgb(42, 42, 42)
    static let backgroundBottom = rgb(19, 19, 19)
    static let currentTop = rgb(51, 115, 244)
    static let currentBottom = rgb(21, 53, 116)
    static let separator = rgb(255, 255, 255, 0.15)
    static let thinSeparator = rgb(255, 255, 255, 0.035)
    static let text = Color.white

    static func color(_ standing: SpeedrunTimer.Standing) -> Color {
        switch standing {
        case .aheadGaining: return rgb(0, 204, 54)
        case .aheadLosing: return rgb(82, 204, 115)
        case .behindGaining: return rgb(204, 92, 82)
        case .behindLosing: return rgb(204, 18, 0)
        case .gold: return rgb(216, 175, 31)
        case .personalBest: return rgb(22, 166, 255)
        case .neutral: return rgb(122, 122, 122)
        }
    }
}

struct TimerView: View {
    @ObservedObject var timer: SpeedrunTimer
    /// False when drawn as a still picture (each frame of a recording).
    var live = true

    static let width: CGFloat = 260
    private let rowHeight: CGFloat = 24
    private let maxRows = 10

    var body: some View {
        if live {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: timer.phase != .running)) { _ in layout }
        } else {
            layout
        }
    }

    private var layout: some View {
        VStack(spacing: 0) {
            title
            separator
            splitsList
            separator
            bigTimer
            previousSegment
        }
        .frame(width: Self.width)
        .background(LinearGradient(colors: [SplitColors.backgroundTop, SplitColors.backgroundBottom], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }

    private var separator: some View {
        Rectangle().fill(SplitColors.separator).frame(height: 2)
    }

    private var title: some View {
        VStack(spacing: 0) {
            Text(timer.splits.game.isEmpty ? "Untitled" : timer.splits.game)
                .font(.system(size: 14, weight: .regular))
            Text(timer.splits.category)
                .font(.system(size: 14))
        }
        .lineLimit(1)
        .foregroundStyle(SplitColors.text)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .padding(.horizontal, 28)
        .overlay(alignment: .bottomTrailing) {
            Text("\(timer.splits.attempts)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(SplitColors.text)
                .padding(.trailing, 6)
                .padding(.bottom, 5)
        }
    }

    /// LiveSplit's default: up to 10 rows that scroll with the run, the final split always shown.
    private var visibleRows: [Int] {
        let count = timer.segmentCount
        guard count > maxRows else { return Array(0..<count) }
        let window = maxRows - 1
        let start = min(max(timer.index - (window - 2), 0), count - 1 - window)
        return Array(start..<(start + window)) + [count - 1]
    }

    private var splitsList: some View {
        VStack(spacing: 0) {
            ForEach(visibleRows, id: \.self) { i in
                row(i)
                    .frame(height: rowHeight)
                    .background(i == timer.index && timer.phase != .idle && timer.phase != .ended
                                ? AnyView(LinearGradient(colors: [SplitColors.currentTop, SplitColors.currentBottom], startPoint: .top, endPoint: .bottom))
                                : AnyView(Color.clear))
                    .overlay(alignment: .bottom) { Rectangle().fill(SplitColors.thinSeparator).frame(height: 1) }
            }
        }
    }

    private func row(_ i: Int) -> some View {
        let segment = timer.splits.segments[i]
        let done = i < timer.index && timer.phase != .idle
        let current = i == timer.index && (timer.phase == .running || timer.phase == .paused)

        var deltaText = ""
        var deltaColor = SplitColors.text
        if done, let d = timer.delta(i) {
            deltaText = SpeedrunFormat.delta(d)
            deltaColor = SplitColors.color(timer.standing(i))
        } else if current, let live = timer.liveDelta {
            deltaText = SpeedrunFormat.delta(live)
            deltaColor = SplitColors.color(.behindLosing)
        }
        let time = done ? SpeedrunFormat.time(timer.times[i]) : SpeedrunFormat.time(segment.pbSplit)

        return HStack(spacing: 4) {
            Text(segment.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(deltaText)
                .foregroundStyle(deltaColor)
                .frame(width: 58, alignment: .trailing)
            Text(time)
                .frame(width: 66, alignment: .trailing)
        }
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(SplitColors.text)
        .padding(.horizontal, 6)
    }

    private var bigTimer: some View {
        let parts = SpeedrunFormat.clock(timer.now)
        let color = SplitColors.color(timer.timerStanding)
        return HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(parts.main).font(.system(size: 46, weight: .semibold).monospacedDigit())
            Text(parts.fraction).font(.system(size: 30, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(LinearGradient(colors: [color.opacity(1), color.opacity(0.78)], startPoint: .top, endPoint: .bottom))
        .shadow(color: .black.opacity(0.6), radius: 0, x: 1, y: 1)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var previousSegment: some View {
        let previous = timer.previousSegment
        return HStack {
            Text("Previous Segment")
            Spacer()
            Text(previous.map { SpeedrunFormat.delta($0.delta) } ?? "-")
                .foregroundStyle(previous.map { SplitColors.color($0.standing) } ?? SplitColors.text)
        }
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(SplitColors.text)
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
    }
}
