//
//  TimelineView.swift
//  AdaEngine
//
//  Created by AdaEngine on 28.05.2026.
//

import AdaUtils
import Foundation

/// A mode that can be used by timeline schedules to reduce their update frequency.
public enum TimelineScheduleMode: Sendable {
    /// The default update mode.
    case normal
    /// A mode for less frequent updates.
    case lowFrequency
}

/// The frequency at which a timeline updates its content.
public enum TimelineCadence: Comparable, Sendable {
    /// The timeline updates as frequently as the UI update loop allows.
    case live
    /// The timeline updates at second-level granularity.
    case seconds
    /// The timeline updates at minute-level granularity.
    case minutes
}

/// Information passed to a timeline content builder.
public struct TimelineViewContext: Sendable {
    public typealias Cadence = TimelineCadence

    /// The date for the current timeline entry.
    public let date: Date
    /// The cadence of the current timeline.
    public let cadence: Cadence

    public init(date: Date, cadence: Cadence) {
        self.date = date
        self.cadence = cadence
    }
}

/// A schedule that produces dates for ``TimelineView`` updates.
public protocol TimelineSchedule {
    /// The sequence of dates produced by the schedule.
    associatedtype Entries: Sequence where Entries.Element == Date

    /// Returns timeline entries beginning at the supplied date.
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries
}

/// A sequence of timeline dates separated by a fixed interval.
public struct TimelineScheduleEntries: Sequence, IteratorProtocol, Sendable {
    private var nextDate: Date?
    private let interval: Double?

    /// Creates an empty entry sequence.
    public static var empty: Self {
        Self(firstDate: nil, interval: nil)
    }

    /// Creates a sequence beginning at `firstDate`.
    public init(firstDate: Date?, interval: Double?) {
        self.nextDate = firstDate
        self.interval = interval
    }

    public mutating func next() -> Date? {
        guard let date = nextDate else {
            return nil
        }

        if let interval {
            nextDate = date.addingTimeInterval(interval)
        } else {
            nextDate = nil
        }

        return date
    }
}

/// A schedule that updates as often as the UI update loop allows, or at a minimum interval.
public struct AnimationTimelineSchedule: TimelineSchedule, Sendable {
    public let minimumInterval: Double?
    public let paused: Bool

    public init(minimumInterval: Double? = nil, paused: Bool = false) {
        self.minimumInterval = minimumInterval
        self.paused = paused
    }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> TimelineScheduleEntries {
        guard !paused else {
            return .empty
        }

        let interval = resolvedInterval(for: mode)
        return TimelineScheduleEntries(
            firstDate: startDate.addingTimeInterval(interval),
            interval: interval
        )
    }

    func nextDate(after date: Date, mode _: TimelineScheduleMode) -> Date? {
        guard !paused else {
            return nil
        }

        guard let minimumInterval else {
            return date
        }

        let interval = max(minimumInterval, Double.ulpOfOne)
        return date.addingTimeInterval(interval)
    }

    func cadence(for mode: TimelineScheduleMode) -> TimelineCadence {
        guard let minimumInterval else {
            return mode == .lowFrequency ? .seconds : .live
        }

        return cadenceFromInterval(minimumInterval)
    }

    private func resolvedInterval(for mode: TimelineScheduleMode) -> Double {
        guard let minimumInterval else {
            return mode == .lowFrequency ? 1 : 1.0 / 60.0
        }

        return max(minimumInterval, Double.ulpOfOne)
    }
}

/// A schedule that updates at a fixed interval starting from a given date.
public struct PeriodicTimelineSchedule: TimelineSchedule, Sendable {
    public let startDate: Date
    public let interval: Double

    public init(from startDate: Date, by interval: Double) {
        self.startDate = startDate
        self.interval = max(interval, Double.ulpOfOne)
    }

    public func entries(from startDate: Date, mode _: TimelineScheduleMode) -> TimelineScheduleEntries {
        TimelineScheduleEntries(
            firstDate: firstDate(onOrAfter: startDate),
            interval: interval
        )
    }

    func nextDate(after date: Date, mode _: TimelineScheduleMode) -> Date? {
        let firstDate = firstDate(onOrAfter: date)
        return firstDate > date ? firstDate : firstDate.addingTimeInterval(interval)
    }

    var cadence: TimelineCadence {
        cadenceFromInterval(interval)
    }

    private func firstDate(onOrAfter date: Date) -> Date {
        guard startDate < date else {
            return startDate
        }

        let elapsed = date.timeIntervalSince(startDate)
        let steps = ceil(elapsed / interval)
        return startDate.addingTimeInterval(steps * interval)
    }
}

/// A schedule that updates once per minute.
public struct EveryMinuteTimelineSchedule: TimelineSchedule, Sendable {
    public init() {}

    public func entries(from startDate: Date, mode _: TimelineScheduleMode) -> TimelineScheduleEntries {
        TimelineScheduleEntries(
            firstDate: Self.minuteDate(onOrAfter: startDate),
            interval: 60
        )
    }

    func nextDate(after date: Date, mode _: TimelineScheduleMode) -> Date? {
        let firstDate = Self.minuteDate(onOrAfter: date)
        return firstDate > date ? firstDate : firstDate.addingTimeInterval(60)
    }

    private static func minuteDate(onOrAfter date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        let minute = 60.0
        let nextMinute = ceil(seconds / minute) * minute
        return Date(timeIntervalSinceReferenceDate: nextMinute)
    }
}

extension TimelineSchedule where Self == AnimationTimelineSchedule {
    /// A schedule that updates as often as the UI update loop allows.
    public static var animation: AnimationTimelineSchedule {
        AnimationTimelineSchedule()
    }

    /// A schedule that updates as often as the UI update loop allows, or at the given minimum interval.
    public static func animation(minimumInterval: Double? = nil, paused: Bool = false) -> AnimationTimelineSchedule {
        AnimationTimelineSchedule(minimumInterval: minimumInterval, paused: paused)
    }
}

extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    /// A schedule that updates at a fixed interval.
    public static func periodic(from startDate: Date, by interval: Double) -> PeriodicTimelineSchedule {
        PeriodicTimelineSchedule(from: startDate, by: interval)
    }
}

extension TimelineSchedule where Self == EveryMinuteTimelineSchedule {
    /// A schedule that updates once per minute.
    public static var everyMinute: EveryMinuteTimelineSchedule {
        EveryMinuteTimelineSchedule()
    }
}

/// A view that updates its content according to a schedule.
public struct TimelineView<Schedule: TimelineSchedule, Content: View>: View, ViewNodeBuilder {
    public typealias Body = Never
    public typealias Context = TimelineViewContext

    public var body: Never {
        fatalError("Unreachable code")
    }

    let schedule: Schedule
    let content: @MainActor (Context) -> Content

    /// Creates a timeline view with the supplied schedule.
    public init(
        _ schedule: Schedule,
        @ViewBuilder content: @escaping @MainActor (Context) -> Content
    ) {
        self.schedule = schedule
        self.content = content
    }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        TimelineViewNode(
            schedule: schedule,
            layout: context.layout,
            contentBuilder: content,
            content: self
        )
    }
}

@MainActor
private final class TimelineContentState<Content: View> {
    typealias Context = TimelineViewContext

    var contentBuilder: @MainActor (Context) -> Content
    var context: Context

    init(
        contentBuilder: @escaping @MainActor (Context) -> Content,
        context: Context
    ) {
        self.contentBuilder = contentBuilder
        self.context = context
    }

    func makeListView(inputs: _ViewListInputs) -> _ViewListOutputs {
        let content = contentBuilder(context)
        return Content._makeListView(_ViewGraphNode(value: content), inputs: inputs)
    }
}

@MainActor
private final class TimelineViewNode<Schedule: TimelineSchedule, Content: View>: LayoutViewContainerNode {
    typealias Context = TimelineViewContext

    private var schedule: Schedule
    private let state: TimelineContentState<Content>
    private var nextDate: Date?
    private var hasBuiltTimelineContent = false
    private let mode: TimelineScheduleMode = .normal

    init<Root: View>(
        schedule: Schedule,
        layout: any Layout,
        contentBuilder: @escaping @MainActor (Context) -> Content,
        content: Root
    ) {
        let now = Date()
        let state = TimelineContentState(
            contentBuilder: contentBuilder,
            context: Context(date: now, cadence: schedule.timelineCadence(for: .normal))
        )

        self.schedule = schedule
        self.state = state
        self.nextDate = schedule.timelineNextDate(after: now, mode: .normal)

        super
            .init(
                layout: AnyLayout(erased: layout),
                content: content,
                bypassSingleChildLayout: true,
                buildImmediately: false,
                body: { inputs in
                    state.makeListView(inputs: inputs)
                }
            )
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        super.updateEnvironment(environment)
        ensureTimelineContent()
    }

    override func update(from newNode: ViewNode) {
        guard let timelineNode = newNode as? TimelineViewNode<Schedule, Content> else {
            super.update(from: newNode)
            return
        }

        schedule = timelineNode.schedule
        state.contentBuilder = timelineNode.state.contentBuilder
        super.update(from: newNode)
        rebuildTimelineContent(date: state.context.date, propagateLayout: false)
        nextDate = schedule.timelineNextDate(after: state.context.date, mode: mode)
    }

    override func update(_ deltaTime: AdaUtils.TimeInterval) {
        ensureTimelineContent()

        let now = Date()
        if let nextDate, now >= nextDate {
            rebuildTimelineContent(date: now, propagateLayout: false)
            self.nextDate = schedule.timelineNextDate(after: now, mode: mode)
        }

        super.update(deltaTime)
    }

    override func invalidateContent() {
        rebuildTimelineContent(date: state.context.date, propagateLayout: true)
    }

    override func invalidateContent(propagateLayout: Bool) {
        rebuildTimelineContent(date: state.context.date, propagateLayout: propagateLayout)
    }

    private func ensureTimelineContent() {
        guard !hasBuiltTimelineContent else {
            return
        }

        rebuildTimelineContent(date: state.context.date, propagateLayout: true)
    }

    private func rebuildTimelineContent(date: Date, propagateLayout: Bool) {
        state.context = Context(date: date, cadence: schedule.timelineCadence(for: mode))
        hasBuiltTimelineContent = true
        super.invalidateContent(propagateLayout: propagateLayout)
    }
}

extension TimelineSchedule {
    func timelineNextDate(after date: Date, mode: TimelineScheduleMode) -> Date? {
        if let schedule = self as? AnimationTimelineSchedule {
            return schedule.nextDate(after: date, mode: mode)
        }

        if let schedule = self as? PeriodicTimelineSchedule {
            return schedule.nextDate(after: date, mode: mode)
        }

        if let schedule = self as? EveryMinuteTimelineSchedule {
            return schedule.nextDate(after: date, mode: mode)
        }

        return entries(from: date, mode: mode).first { $0 > date }
    }

    func timelineCadence(for mode: TimelineScheduleMode) -> TimelineCadence {
        if let schedule = self as? AnimationTimelineSchedule {
            return schedule.cadence(for: mode)
        }

        if let schedule = self as? PeriodicTimelineSchedule {
            return schedule.cadence
        }

        if self is EveryMinuteTimelineSchedule {
            return .minutes
        }

        return .live
    }
}

private func cadenceFromInterval(_ interval: Double) -> TimelineCadence {
    if interval < 1 {
        return .live
    }

    if interval < 60 {
        return .seconds
    }

    return .minutes
}
