import Foundation

/// Built-in worship-style sample so ProShow demos with no external assets.
enum SampleContent {
    static func sundayMorningService() -> (show: Show, playlist: Playlist) {
        let title = SlideGroup(
            name: "Title",
            colorHex: "#8B7355",
            slides: [
                Slide(
                    title: "Welcome",
                    lines: ["Good morning", "Welcome to worship"],
                    notes: "House lights up; band soft"
                ),
            ]
        )

        let verse1 = SlideGroup(
            name: "Verse 1",
            colorHex: "#3D7EA6",
            slides: [
                Slide(
                    lines: [
                        "Amazing grace, how sweet the sound",
                        "That saved a wretch like me",
                    ]
                ),
                Slide(
                    lines: [
                        "I once was lost, but now am found",
                        "Was blind, but now I see",
                    ]
                ),
            ]
        )

        let chorus = SlideGroup(
            name: "Chorus",
            colorHex: "#C45C26",
            slides: [
                Slide(
                    lines: [
                        "Hallelujah, grace like a river",
                        "Flowing freely to me",
                    ]
                ),
                Slide(
                    lines: [
                        "Hallelujah, mercy unending",
                        "Jesus, my victory",
                    ]
                ),
            ]
        )

        let verse2 = SlideGroup(
            name: "Verse 2",
            colorHex: "#3D7EA6",
            slides: [
                Slide(
                    lines: [
                        "Through many dangers, toils, and snares",
                        "I have already come",
                    ]
                ),
                Slide(
                    lines: [
                        "'Tis grace that brought me safe thus far",
                        "And grace will lead me home",
                    ]
                ),
            ]
        )

        let bridge = SlideGroup(
            name: "Bridge",
            colorHex: "#6B4C9A",
            slides: [
                Slide(
                    lines: [
                        "My chains are gone, I've been set free",
                        "My God, my Savior has ransomed me",
                    ]
                ),
            ]
        )

        let clear = SlideGroup(
            name: "Clear",
            colorHex: "#555555",
            slides: [
                Slide(title: "Blank", notes: "Clear audience / black", isBlank: true),
            ]
        )

        let show = Show(
            name: "Amazing Grace (Sample)",
            groups: [title, verse1, chorus, verse2, bridge, clear],
            notes: "Sample worship lyrics show bundled with ProShow. Original demo content."
        )

        let playlist = Playlist(
            name: "Sunday Morning",
            items: [
                PlaylistItem(kind: .note, title: "Pre-service", detail: "Loop welcome slides"),
                PlaylistItem(kind: .show, title: show.name, showID: show.id),
                PlaylistItem(kind: .spacer, title: "—"),
                PlaylistItem(kind: .note, title: "Message", detail: "Speaker notes elsewhere"),
            ]
        )

        return (show, playlist)
    }
}
