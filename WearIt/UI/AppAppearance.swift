//
//  AppAppearance.swift
//  WearIt
//
//  Created by Dor David on 21/10/2025.
//  Updated for iOS 18+ Liquid Glass Design System
//

import SwiftUI

enum AppAppearance {
    static func install() {
        // Unlock + tune ProMotion (120Hz) — see ProMotionSupport / Apple docs.
        ProMotionSupport.install()

        // Keep container chrome translucent so LiquidGlassBackdrop
        // is visible behind every tab — including iOS 26 Liquid Glass.
        clearContainerBackgrounds()
        installTransparentBarAppearances()
    }

    private static func clearContainerBackgrounds() {
        UITabBar.appearance().isTranslucent = true
        UITabBar.appearance().backgroundColor = .clear
        UINavigationBar.appearance().isTranslucent = true
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
        UIScrollView.appearance().backgroundColor = .clear
    }

    private static func installTransparentBarAppearances() {
        // Fully clear chrome so the app wallpaper continues under
        // status / nav / tab regions (no black material strips).
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = .clear
        nav.backgroundEffect = nil
        nav.shadowColor = .clear

        nav.titleTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        nav.largeTitleTextAttributes = [
            .foregroundColor: UIColor.label,
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]

        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().compactScrollEdgeAppearance = nav
        UINavigationBar.appearance().isTranslucent = true

        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundColor = .clear
        tab.backgroundEffect = nil
        tab.shadowColor = .clear

        tab.stackedLayoutAppearance.normal.iconColor = .secondaryLabel
        tab.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor.secondaryLabel,
            .font: UIFont.systemFont(ofSize: 10, weight: .medium)
        ]
        tab.stackedLayoutAppearance.selected.iconColor = .tintColor
        tab.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor.tintColor,
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold)
        ]

        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().isTranslucent = true
        UITabBar.appearance().backgroundColor = .clear
    }
}
