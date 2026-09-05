import SwiftUI

extension ToolbarContent {
    /// Removes the capsule macOS 26 draws behind every toolbar item.
    ///
    /// That chrome makes a plain label — the bot's name — read as a button, and groups
    /// adjacent icons into one shared pill. Items styled this way sit flat on the
    /// window and supply their own hover state instead.
    ///
    /// Guarded rather than raising the deployment target: the capsule does not exist
    /// before macOS 26, so on older systems there is nothing to hide.
    @ToolbarContentBuilder
    func flatBackground() -> some ToolbarContent {
        if #available(macOS 26.0, iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
