import SwiftUI

/// Product-owned Apple TV mark shared by Preferences and the Remote device
/// selector. Keeping the artwork here ensures every device picker uses the
/// same native/vector treatment and remains sharp at any display scale.
struct AppleTVLogoTile: View {
    let size: CGFloat
    var selected = false
    var cornerRadius: CGFloat? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                .fill(selected ? AppConstants.controlHighlight : AppConstants.controlBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)
                        .stroke(
                            selected ? Color.white.opacity(0.70) : AppConstants.controlBorder,
                            lineWidth: selected ? 1.1 : 0.8
                        )
                }

            HStack(spacing: max(0.5, size * 0.014)) {
                Image(systemName: "apple.logo")
                    .font(.system(size: size * 0.39, weight: .semibold))
                    .offset(y: -size * 0.014)

                Text("tv")
                    .font(.system(size: size * 0.445, weight: .medium))
                    .tracking(-size * 0.021)
            }
            .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var resolvedCornerRadius: CGFloat {
        cornerRadius ?? size * 0.236
    }
}
