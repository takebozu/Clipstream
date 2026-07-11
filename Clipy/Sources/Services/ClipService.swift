//
//  ClipService.swift
//
//  BoltClip
//  GitHub: https://github.com/takebozu/BoltClip
//
//  Created by Econa77 on 2016/11/17.
//
//  Copyright © 2015-2018 Clipy Project.
//  Copyright © 2026 Satoshi Takezawa
//

import Foundation
import Cocoa
import SwiftData
import PINCache
import RxSwift
import RxCocoa

final class ClipService {

    // MARK: - Properties
    fileprivate var cachedChangeCount = BehaviorRelay<Int>(value: 0)
    fileprivate var storeTypes = [String: NSNumber]()
    fileprivate let scheduler = SerialDispatchQueueScheduler(qos: .userInteractive)
    fileprivate let lock = NSRecursiveLock(name: "me.takezawa.BoltClip.ClipUpdatable")
    fileprivate var disposeBag = DisposeBag()

    // MARK: - Clips
    func startMonitoring() {
        disposeBag = DisposeBag()
        // Pasteboard observe timer
        Observable<Int>.interval(.milliseconds(750), scheduler: scheduler)
            .map { _ in NSPasteboard.general.changeCount }
            .withLatestFrom(cachedChangeCount.asObservable()) { ($0, $1) }
            .filter { $0 != $1 }
            .subscribe(onNext: { [weak self] changeCount, _ in
                self?.cachedChangeCount.accept(changeCount)
                self?.create()
            })
            .disposed(by: disposeBag)
        // Store types
        AppEnvironment.current.defaults.rx
            .observe([String: NSNumber].self, Constants.UserDefaults.storeTypes)
            .compactMap { $0 }
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] in
                self?.storeTypes = $0
            })
            .disposed(by: disposeBag)
    }

    func clearAll() {
        let context = ModelContext(AppEnvironment.current.modelContainer)
        let descriptor = FetchDescriptor<CPYClip>()
        guard let clips = try? context.fetch(descriptor) else { return }

        // Delete saved images
        clips
            .filter { !$0.thumbnailPath.isEmpty }
            .map { $0.thumbnailPath }
            .forEach { PINCache.shared.removeObject(forKey: $0) }
        // Delete from SwiftData
        clips.forEach { context.delete($0) }
        try? context.save()
        // Delete written datas
        AppEnvironment.current.dataCleanService.cleanDatas()
    }

    func delete(with clip: CPYClip) {
        let context = ModelContext(AppEnvironment.current.modelContainer)
        // Delete saved images
        let path = clip.thumbnailPath
        if !path.isEmpty {
            PINCache.shared.removeObject(forKey: path)
        }
        // Delete from SwiftData
        let hash = clip.dataHash
        var descriptor = FetchDescriptor<CPYClip>(predicate: #Predicate { $0.dataHash == hash })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
            try? context.save()
        }
    }

    func incrementChangeCount() {
        cachedChangeCount.accept(cachedChangeCount.value + 1)
    }

}

// MARK: - Create Clip
extension ClipService {
    fileprivate func create() {
        lock.lock(); defer { lock.unlock() }

        // Store types
        if !storeTypes.values.contains(NSNumber(value: true)) { return }
        // Pasteboard types
        let pasteboard = NSPasteboard.general
        let types = self.types(with: pasteboard)
        if types.isEmpty { return }

        // Excluded application
        guard !AppEnvironment.current.excludeAppService.frontProcessIsExcludedApplication() else { return }
        // Special applications
        guard !AppEnvironment.current.excludeAppService.copiedProcessIsExcludedApplications(pasteboard: pasteboard) else { return }

        // Create data
        let data = CPYClipData(pasteboard: pasteboard, types: types)
        save(with: data)
    }

    func create(with image: NSImage) {
        lock.lock(); defer { lock.unlock() }

        // Create only image data
        let data = CPYClipData(image: image)
        save(with: data)
    }

    fileprivate func save(with data: CPYClipData) {
        // Don't save empty string history
        if data.isOnlyStringType && data.stringValue.isEmpty { return }

        let isCopySameHistory = AppEnvironment.current.defaults.bool(forKey: Constants.UserDefaults.copySameHistory)
        let isOverwriteHistory = AppEnvironment.current.defaults.bool(forKey: Constants.UserDefaults.overwriteSameHistory)

        let context = ModelContext(AppEnvironment.current.modelContainer)

        // Stable, collision-free content identity (survives relaunch)
        let contentKey = data.contentHashString

        // Look for an existing clip with identical content
        var existingDescriptor = FetchDescriptor<CPYClip>(predicate: #Predicate { $0.contentHash == contentKey })
        existingDescriptor.fetchLimit = 1
        if let existingClip = try? context.fetch(existingDescriptor).first {
            if isOverwriteHistory {
                // Move the existing entry to the top instead of inserting a duplicate
                existingClip.updateTime = Int(Date().timeIntervalSince1970)
                saveContext(context)
                return
            }
            if !isCopySameHistory {
                // Keeping duplicates is disabled
                return
            }
            // Otherwise fall through and store a new, independent entry
        }

        // Saved time and path
        let unixTime = Int(Date().timeIntervalSince1970)
        let savedPath = CPYUtilities.applicationSupportFolder() + "/\(NSUUID().uuidString).data"
        // Create clip object with a guaranteed-unique key
        let clip = CPYClip()
        clip.dataPath = savedPath
        if data.stringValue.isEmpty && !data.fileNames.isEmpty {
            clip.title = data.fileNames.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        } else {
            clip.title = data.stringValue[0...10000]
        }
        clip.dataHash = NSUUID().uuidString
        clip.contentHash = contentKey
        clip.updateTime = unixTime
        clip.primaryType = data.primaryType?.rawValue ?? ""

        // Save thumbnail image
        if let thumbnailImage = data.thumbnailImage {
            PINCache.shared.setObjectAsync(thumbnailImage, forKey: "\(unixTime)", completion: nil)
            clip.thumbnailPath = "\(unixTime)"
        }
        if let colorCodeImage = data.colorCodeImage {
            PINCache.shared.setObjectAsync(colorCodeImage, forKey: "\(unixTime)", completion: nil)
            clip.thumbnailPath = "\(unixTime)"
            clip.isColorCode = true
        }

        // Save SwiftData and .data file
        guard CPYUtilities.prepareSaveToPath(CPYUtilities.applicationSupportFolder()) else { return }
        guard let archivedData = try? NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: false) else { return }
        guard (try? archivedData.write(to: URL(fileURLWithPath: savedPath))) != nil else { return }

        context.insert(clip)
        saveContext(context)
    }

    /// Saves the context, rolling back and logging on failure so a single failed
    /// save can never leave the context wedged and silently drop every future clip.
    private func saveContext(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            context.rollback()
            NSLog("[BoltClip] Failed to save clipboard history: \(error)")
        }
    }

    private func types(with pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let filteredTypes = pasteboard.types?.filter { canSave(with: $0) } ?? []
        let uniqueTypes = NSOrderedSet(array: filteredTypes).array as? [NSPasteboard.PasteboardType] ?? []

        // URL payloads often include a plain-string flavor as well.
        // Prefer semantic types so clips are categorized by the richer format.
        let typePriority: [NSPasteboard.PasteboardType: Int] = [
            .fileURL: 0,
            .URL: 1,
            .rtfd: 2,
            .rtf: 3,
            .pdf: 4,
            .tiff: 5,
            .string: 6
        ]

        return uniqueTypes
            .enumerated()
            .sorted {
                let leftPriority = typePriority[$0.element] ?? Int.max
                let rightPriority = typePriority[$1.element] ?? Int.max
                if leftPriority == rightPriority {
                    return $0.offset < $1.offset
                }
                return leftPriority < rightPriority
            }
            .map { $0.element }
    }

    private func canSave(with type: NSPasteboard.PasteboardType) -> Bool {
        let dictionary = CPYClipData.availableTypesDictionary
        guard let value = dictionary[type] else { return false }
        guard let number = storeTypes[value] else { return false }
        return number.boolValue
    }
}
