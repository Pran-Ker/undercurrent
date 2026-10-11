import SwiftUI
import Charts

// The board's biometrics: stat tiles with a YOU marker and an IDEAL band, a 30-day line, a weekly
// bar chart, tags, what is due. All of it from the real board; nothing here is illustrative.
struct InsightsView: View {
    @Environment(Board.self) private var board

    private var insights: Insights { Insights.compute(tasks: board.tasks, events: board.events) }

    var body: some View {
        let i = insights
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: "Your biometrics")
                    TwoToneTitle(first: "Track the board", second: "read the current", size: 28)
                    Text("How much is decided, how long things sit, how fast they close.")
                        .font(Theme.small(14)).foregroundStyle(Theme.muted)
                }

                if board.tasks.isEmpty {
                    Card { EmptyLine(text: board.loading ? "Loading the board…" : "Nothing on the board yet. Measures appear once there are tasks.") }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(i.measures) { StatTile(measure: $0) }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("OPEN · LAST 30 DAYS").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                                Spacer()
                                legend
                            }
                            Chart {
                                ForEach(i.series) { p in
                                    AreaMark(x: .value("Day", p.day), y: .value("Open", p.open))
                                        .foregroundStyle(LinearGradient(colors: [Theme.slateLight.opacity(0.7), Theme.slateLight.opacity(0)], startPoint: .top, endPoint: .bottom))
                                        .interpolationMethod(.monotone)
                                    LineMark(x: .value("Day", p.day), y: .value("Open", p.open))
                                        .foregroundStyle(Theme.inkDeep)
                                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                                        .interpolationMethod(.monotone)
                                    LineMark(x: .value("Day", p.day), y: .value("Closed", p.closed), series: .value("Series", "closed"))
                                        .foregroundStyle(Theme.slateFill)
                                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                        .interpolationMethod(.monotone)
                                }
                            }
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairline)
                                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), anchor: .top)
                                        .font(Theme.mono(9)).foregroundStyle(Theme.muted)
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading) { _ in
                                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairline)
                                    AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.muted)
                                }
                            }
                            .frame(height: 170)
                            .accessibilityLabel("Open tasks over the last 30 days")
                        }
                    }
                    .accessibilityIdentifier("chart.open")

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("WRITTEN AND CLOSED · PER WEEK").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                            Chart {
                                ForEach(i.closedPerWeek) { p in
                                    BarMark(x: .value("Week", p.day, unit: .weekOfYear), y: .value("Written", p.open), width: .ratio(0.3))
                                        .foregroundStyle(Theme.slateLight)
                                        .position(by: .value("Kind", "written"))
                                    BarMark(x: .value("Week", p.day, unit: .weekOfYear), y: .value("Closed", p.closed), width: .ratio(0.3))
                                        .foregroundStyle(Theme.inkDeep)
                                        .position(by: .value("Kind", "closed"))
                                }
                            }
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), anchor: .top)
                                        .font(Theme.mono(9)).foregroundStyle(Theme.muted)
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading) { _ in
                                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairline)
                                    AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.muted)
                                }
                            }
                            .frame(height: 150)
                            .accessibilityLabel("Tasks written and closed per week, last 8 weeks")
                            HStack(spacing: 14) {
                                legendDot(Theme.slateLight, "written")
                                legendDot(Theme.inkDeep, "closed")
                            }
                        }
                    }
                    .accessibilityIdentifier("chart.weekly")

                    if !i.dueSoon.isEmpty || !i.overdue.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("DUE").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                                ForEach(Array((i.overdue + i.dueSoon).enumerated()), id: \.element.id) { n, t in
                                    NumberedRow(index: n + 1) {
                                        HStack {
                                            Text(t.text).font(Theme.body(15)).foregroundStyle(Theme.ink).lineLimit(1)
                                            Spacer()
                                            Chip(text: Dates.short(t.due), tone: i.overdue.contains(t) ? .warn : .neutral, mono: true)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !i.tags.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("OPEN BY TAG").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                                let top = Double(i.tags.first?.count ?? 1)
                                ForEach(i.tags) { tc in
                                    HStack(spacing: 10) {
                                        Text("#" + tc.tag).font(Theme.small(13)).foregroundStyle(Theme.ink).frame(width: 90, alignment: .leading).lineLimit(1)
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Theme.slateLight).frame(height: 4)
                                                Capsule().fill(Theme.inkDeep).frame(width: geo.size.width * CGFloat(Double(tc.count) / top), height: 4)
                                            }
                                            .frame(maxHeight: .infinity)
                                        }
                                        .frame(height: 12)
                                        Text("\(tc.count)").font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 24, alignment: .trailing)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }

                    if !i.actors.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("WHO DID WHAT").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                                HStack(spacing: 18) {
                                    ForEach(i.actors, id: \.actor) { a in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(a.count)").font(Theme.numeral(30)).foregroundStyle(Theme.inkDeep)
                                            Text(a.actor.uppercased()).font(Theme.mono(9)).tracking(1).foregroundStyle(Theme.muted)
                                        }
                                    }
                                }
                                Text("Events on the board by who made them.").font(Theme.small(13)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                Color.clear.frame(height: 20)
            }
            .padding(Theme.gutter)
        }
        .scrollIndicators(.hidden)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .refreshable { await board.refresh() }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(Theme.inkDeep, "open")
            legendDot(Theme.slateFill, "closed, cumulative")
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 6)
            Text(label.uppercased()).font(Theme.mono(9)).tracking(0.8).foregroundStyle(Theme.muted)
        }
    }
}
