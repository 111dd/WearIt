//
//  UIApplication+EndEditing.swift
//  WearIt
//
//  Created by Dor David on 21/10/2025.
//

import UIKit

extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
