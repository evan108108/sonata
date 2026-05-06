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

    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()

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
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }
}
