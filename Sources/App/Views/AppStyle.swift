//
//  AppStyle.swift
//  mkey
//

import SwiftUI

enum AppStyle {
    static let contentMaxWidth: CGFloat = 680
    static let controlCornerRadius: CGFloat = 7
    static let cardCornerRadius: CGFloat = 8
}

struct SettingsFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .font(.body)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .frame(maxWidth: AppStyle.contentMaxWidth, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    func settingsFormStyle() -> some View {
        modifier(SettingsFormStyle())
    }
}
