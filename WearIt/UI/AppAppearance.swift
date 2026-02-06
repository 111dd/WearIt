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
        // UINavigationBar - iOS 18+ Enhanced
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        nav.backgroundColor = .clear
        nav.shadowColor = .clear
        
        // iOS 18+ title styling
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

        // UITabBar - iOS 18+ Enhanced
        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        tab.backgroundColor = .clear
        tab.shadowColor = .clear
        
        // iOS 18+ tab item styling
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
    }
}
