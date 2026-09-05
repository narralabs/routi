import SwiftUI

/// The rounded-square bot avatar with the two-dot face, drawn rather than shipped as
/// an asset so it tints to any bot colour and stays crisp at every size.
struct BotAvatar: View {
    let color: Color
    var size: CGFloat = 34
    var isBusy: Bool = false

    var body: some View {
        // `.rect(cornerRadius:style: .continuous)` is the Apple squircle; a plain
        // circular radius reads subtly boxy next to real app icons.
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                HStack(spacing: size * 0.16) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule()
                            .fill(.white.opacity(0.95))
                            .frame(width: size * 0.1, height: size * 0.2)
                    }
                }
                .offset(y: -size * 0.02)
            }
            .overlay(alignment: .bottomTrailing) {
                if isBusy {
                    Circle()
                        .fill(.green)
                        .frame(width: size * 0.28, height: size * 0.28)
                        .overlay(Circle().stroke(.background, lineWidth: size * 0.055))
                        .offset(x: size * 0.04, y: size * 0.04)
                }
            }
    }
}
