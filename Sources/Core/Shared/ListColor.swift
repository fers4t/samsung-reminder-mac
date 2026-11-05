import SwiftUI

/// Samsung's eight fixed list colours, approximated for AppKit rendering.
public enum ListColor {
    public static func color(_ index: Int) -> Color {
        switch index {
        case 1: .red
        case 2: .orange
        case 3: .yellow
        case 4: .green
        case 5: .teal
        case 6: .blue
        case 7: .purple
        default: .gray
        }
    }
}
