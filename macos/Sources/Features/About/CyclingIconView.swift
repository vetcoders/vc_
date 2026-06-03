import SwiftUI

/// The canonical vc_ user-facing brand mark.
struct CyclingIconView: View {
    var body: some View {
        Image("VcBrandImage")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 128, height: 128)
            .accessibilityLabel("vc_ application icon")
    }
}
