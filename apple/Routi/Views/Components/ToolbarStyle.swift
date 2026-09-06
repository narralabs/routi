import SwiftUI

/// Pushes whatever follows to the trailing edge of the toolbar.
///
/// `.primaryAction` alone does not right-align here: in a NavigationSplitView the
/// detail column's items pack from its leading edge, so the screen toggle sat next to
/// the bot's name instead of opposite it. `ToolbarSpacer` is macOS 26 and the target
/// is 14, hence the guard — on older systems the items simply stay grouped, which is
/// the behaviour they had anyway.
@ToolbarContentBuilder
func flexibleToolbarSpacer() -> some ToolbarContent {
    if #available(macOS 26.0, iOS 26.0, *) {
        ToolbarSpacer(.flexible, placement: .primaryAction)
    }
}

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
