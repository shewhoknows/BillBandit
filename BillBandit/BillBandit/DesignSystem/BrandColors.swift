import SwiftUI

extension Color {
    /// BillBandit brand palette — Direction B "Cobalt Club" (approved 2026-07-17).
    enum Brand {
        /// #1F3FC3 — full-bleed screen background
        static let cobalt     = Color(red: 0x1F/255, green: 0x3F/255, blue: 0xC3/255)
        /// #17309C — tab bar / recessed chrome
        static let cobaltDeep = Color(red: 0x17/255, green: 0x30/255, blue: 0x9C/255)
        /// #EFEFD7 — primary cream
        static let cream      = Color(red: 0xEF/255, green: 0xEF/255, blue: 0xD7/255)
        /// #F5F3E4 — card/sheet cream
        static let creamSoft  = Color(red: 0xF5/255, green: 0xF3/255, blue: 0xE4/255)
        /// #2942C9 — official mascot ink (as shipped in BillBandit-Raccoon-SVG)
        static let mascotInk   = Color(red: 0x29/255, green: 0x42/255, blue: 0xC9/255)
        /// #F7F1DD — official mascot cream (as shipped)
        static let mascotCream = Color(red: 0xF7/255, green: 0xF1/255, blue: 0xDD/255)
    }
}
