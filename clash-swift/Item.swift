//
//  Item.swift
//  clash-swift
//
//  Created by AnNabe1la on 2026/8/4.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
