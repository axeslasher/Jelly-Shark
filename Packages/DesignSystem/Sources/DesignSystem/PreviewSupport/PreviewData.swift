import Foundation

#if DEBUG
    /// Fictional sample data for `#Preview` bodies. Debug-only: release builds
    /// contain no PreviewData symbols, so any `#Preview` that references this
    /// type must itself be wrapped in `#if DEBUG` (preview bodies type-check in
    /// Release even though the symbols are stripped).
    ///
    /// Titles, people, and roles are invented; artwork is synthesized from the
    /// blurhash constants, whose validity is enforced by `PreviewSupportTests`.
    /// Features has its own `PreviewData` with `MediaItem` fixtures — reference
    /// this one as `DesignSystem.PreviewData` where the names collide.
    public enum PreviewData {
        /// Portrait (3x4 component) hashes sized for poster slots.
        public static let posterHashes = [
            "T9Au:Bt65S1NS4xD5Tf6s.-9j@WV", // dusk orange over slate
            "T25M@},@1u6$SM$51uS2wy=0o1Nu", // blood-red fade
            "TA5ZzfVZQkMIaekWQ*kCkDpJf7ae", // electric blue
            "TVDI%VxtIW~2s,NLr;jZWXj]juay", // gold over blue
            "T43TYey;QUQUaLo|L%VZkVt*kVaL", // deep teal
            "TFEv~~WFAA0|WUxGAAj?oM$+juWV", // neon magenta
            "TdD]rRxuRj~qt7WB%2oeayxuj[ay", // overcast grey
            "TSEd9sspEf}roLNbS1j?a#j[jtay", // sunset purple
            "T68gmTIV0LD*WBxa0Lt7xt%LfQR*", // noir spotlight
            "T65FT}x?Mh?;oxRSayfQagj[j@ay", // forest green
            "TTJjM8?GE2~pt7RjF2WXjZxaoLWV", // desert sand
            "TLD+_M~pW94;NHofE0NGa#xuofay", // dawn indigo
        ]

        /// Landscape (4x3 component) hashes sized for backdrop/thumb slots.
        public static let backdropHashes = [
            "L35;g^I,9qxcJ4axoNa{9psqs;WU", // night city haze
            "LMD]}Ax]IAtR0iR+t5WCDiWBofae", // coastal horizon
            "LHDQ[J=w5mWWIrazs.j@10NbxFaz", // ember field
            "L24CClj[8xt7M{aet7j[8wj[xuWB", // fog bank
        ]

        /// Never decodes; use to preview the placeholder-fallback path.
        public static let invalidHash = "not-a-blurhash"

        /// Twelve fictional titles — one per poster hash, shelf-sized.
        public static let movieTitles = [
            "The Cartographer's Daughter",
            "Midnight at Halberd Creek",
            "Signal Decay",
            "The Glass Antenna",
            "Winterglass Harvest",
            "A Field Guide to Vanishing",
            "Copper Canyon Overdrive",
            "The Marrow Deep",
            "Static Bloom",
            "Last Train to Veldt",
            "The Unmoored",
            "Paper Lantern Republic",
        ]

        public static let shortTitle = "Veldt"

        /// Long enough to exercise truncation in any card layout.
        public static let longTitle =
            "The Remarkably Slow and Entirely Unstoppable Decline of the Halberd Creek Bowling League"

        public static let peopleNames = [
            "Marisol Vane",
            "Teddy Okafor",
            "June Castellane",
            "Arno Pike",
            "Priya Ramanathan",
            "Wallace Thorn",
            "Ida Kroll",
            "Sam Beaufort",
        ]

        public static let roles = [
            "Elenora Swift",
            "Det. Marsh",
            "The Caretaker",
            "Dr. Ilse Hammond",
            "Young Petra",
            "Narrator",
            "Ferryman",
            "Miss Halloway",
        ]

        public static let overview = """
        When a decommissioned lighthouse begins broadcasting weather reports for \
        storms that have not happened yet, cartographer Elenora Swift returns to \
        the island she spent twenty years avoiding. What she finds in the lamp \
        room forces her to redraw every map she has ever trusted — starting with \
        the one of her own family.
        """
    }
#endif
