import Foundation

/// Compatibility facade — returns an empty slate (legacy tests may still call bundled seed APIs directly).
enum SampleContent {
    static func starterProgram() -> (show: Show, playlist: Playlist) {
        (DefaultSeedData.blankShow(), DefaultSeedData.emptyPlaylist())
    }

    static func sundayMorningService() -> (show: Show, playlist: Playlist) {
        starterProgram()
    }
}
