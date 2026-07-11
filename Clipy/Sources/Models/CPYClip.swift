//
//  CPYClip.swift
//
//  BoltClip
//  GitHub: https://github.com/takebozu/BoltClip
//
//  Created by Econa77 on 2015/06/21.
//
//  Copyright © 2015-2018 Clipy Project.
//  Copyright © 2026 Satoshi Takezawa
//

import Cocoa
import SwiftData

@Model
final class CPYClip {

    // MARK: - Properties
    var dataPath: String = ""
    var title: String = ""
    /// Guaranteed-unique identifier used as the menu's lookup key.
    @Attribute(.unique) var dataHash: String = ""
    /// Stable hash of the clip's content, used for duplicate detection and
    /// "overwrite same history". Unlike `dataHash` this is intentionally NOT
    /// unique, so it can never trigger a constraint conflict on save.
    var contentHash: String = ""
    var primaryType: String = ""
    var updateTime: Int = 0
    var thumbnailPath: String = ""
    var isColorCode: Bool = false

    init() {}

    init(dataPath: String = "", title: String = "", dataHash: String = "",
         contentHash: String = "", primaryType: String = "", updateTime: Int = 0,
         thumbnailPath: String = "", isColorCode: Bool = false) {
        self.dataPath = dataPath
        self.title = title
        self.dataHash = dataHash
        self.contentHash = contentHash
        self.primaryType = primaryType
        self.updateTime = updateTime
        self.thumbnailPath = thumbnailPath
        self.isColorCode = isColorCode
    }

}
