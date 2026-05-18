import SwiftUI
import Charts

// MARK: - Models

struct DailySpendPoint: Identifiable, Decodable, Equatable {
    let date: String
    let spendUSD: Double
    let totalTokens: Int64

    var id: String { date }
}

private struct TodaySpend: Decodable, Equatable {
    let spendUSD: Double
    let totalTokens: Int64
}

private struct TopConsumerPayload: Decodable, Equatable {
    let label: String
    let spendUSD: Double
}

private struct AnomalyPayload: Decodable, Equatable {
    let flagged: Bool
    let ratio: Double?
}

private struct TokenUsagePayload: Decodable {
    let today: TodaySpend
    let dailyTotals: [DailySpendPoint]
    let topConsumer: TopConsumerPayload?
    let anomaly: AnomalyPayload
    let generatedAt: Int64
}

// MARK: - View Model

@MainActor
final class TokenUsageViewModel: ObservableObject {
    @Published var hasLoadedOnce = false
    @Published var todaySpend: Double = 0
    @Published var todayTokens: Int64 = 0
    @Published var dailyTotals: [DailySpendPoint] = []
    @Published var topConsumerLabel: String?
    @Published var topConsumerSpend: Double = 0
    @Published var anomalyFlagged: Bool = false
    @Published var anomalyRatio: Double?

    func fetch() async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/token_usage")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(TokenUsagePayload.self, from: data)
            self.todaySpend = decoded.today.spendUSD
            self.todayTokens = decoded.today.totalTokens
            self.dailyTotals = decoded.dailyTotals
            self.topConsumerLabel = decoded.topConsumer?.label
            self.topConsumerSpend = decoded.topConsumer?.spendUSD ?? 0
            self.anomalyFlagged = decoded.anomaly.flagged
            self.anomalyRatio = decoded.anomaly.ratio
            self.hasLoadedOnce = true
        } catch {
            // Quiet on transient failures.
        }
    }
}

// MARK: - Card

struct TokenUsageCard: View {
    @ObservedObject var vm: TokenUsageViewModel
    @State private var hoveredDate: String?

    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()

    private static let tokenFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    private static let hoverDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()

    private static let isoDateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func prettyDate(_ iso: String) -> String {
        guard let d = Self.isoDateParser.date(from: iso) else { return iso }
        return Self.hoverDateFormatter.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Token Usage")
                    .font(.headline)
                Text("today + last 7d")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.anomalyFlagged, let ratio = vm.anomalyRatio {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                        Text(String(format: "%.1f× yesterday", ratio))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                }
            }

            if !vm.hasLoadedOnce {
                Color.clear.frame(height: 80)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.usdFormatter.string(from: NSNumber(value: vm.todaySpend)) ?? "$0.00")
                        .font(.system(.largeTitle, design: .rounded).bold())
                        .foregroundStyle(.orange)

                    HStack(spacing: 6) {
                        Text("today")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let label = vm.topConsumerLabel, vm.topConsumerSpend > 0 {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(label)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(Self.usdFormatter.string(from: NSNumber(value: vm.topConsumerSpend)) ?? "$0")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    sparkline
                        .frame(height: 40)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var sparkline: some View {
        if vm.dailyTotals.allSatisfy({ $0.spendUSD == 0 }) {
            Text("No spend in the last 7 days")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Chart(vm.dailyTotals) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value("USD", point.spendUSD)
                )
                .foregroundStyle(.orange)
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("Day", point.date),
                    y: .value("USD", point.spendUSD)
                )
                .foregroundStyle(LinearGradient(
                    colors: [Color.orange.opacity(0.35), Color.orange.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .interpolationMethod(.monotone)

                if let hoveredDate, hoveredDate == point.date {
                    RuleMark(x: .value("Day", point.date))
                        .foregroundStyle(Color.orange.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    PointMark(
                        x: .value("Day", point.date),
                        y: .value("USD", point.spendUSD)
                    )
                    .foregroundStyle(.orange)
                    .symbolSize(60)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(
                        x: .fit(to: .chart), y: .disabled
                    )) {
                        hoverTooltip(for: point)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXSelection(value: $hoveredDate)
        }
    }

    @ViewBuilder
    private func hoverTooltip(for point: DailySpendPoint) -> some View {
        let usd = Self.usdFormatter.string(from: NSNumber(value: point.spendUSD)) ?? "$0"
        let tokens = Self.tokenFormatter.string(from: NSNumber(value: point.totalTokens)) ?? "0"
        VStack(alignment: .leading, spacing: 2) {
            Text(prettyDate(point.date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(usd)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.orange)
            Text("\(tokens) tok")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.85))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        )
    }
}
