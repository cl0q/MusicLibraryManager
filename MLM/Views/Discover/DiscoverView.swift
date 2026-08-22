import SwiftUI

/// The single Discover destination groups recommendations and video-based
/// identification without duplicating either workflow in the sidebar.
struct DiscoverView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case recommendations = "Recommendations"
        case reels = "Reels"

        var id: Self { self }
    }

    @State private var selectedTab: Tab = .recommendations

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Discover")
                    .font(MLMFont.pageTitle)
                    .foregroundColor(.mlmInk)

                Spacer()

                Picker("Discover content", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        if tab == .recommendations {
                            Text("Recommendations").tag(tab)
                        } else {
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch selectedTab {
            case .recommendations:
                DiscoveryInboxView()
            case .reels:
                ReelsInboxView()
            }
        }
        .background(Color.mlmBase)
    }
}
