import SwiftUI

struct TransferPage: View {
    @Bindable var session: TransferSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("File Transfer").font(.title3.weight(.semibold))
                BetaBadge()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            Spacer()
        }
    }
}
