//
//  FoundationFileSystem.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/22/23.
//

import Foundation

final class FoundationFileSystem: FileSystem, @unchecked Sendable {
    let fileManager: FileManager = .default

    // swiftlint:disable force_try
    override var applicationFolderURL: URL {
        #if MACOS
            return Bundle.main.bundleURL.deletingLastPathComponent()
        #elseif IOS || TVOS
            return try! self.fileManager.url(for: .applicationDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #else
            return URL(fileURLWithPath: fileManager.currentDirectoryPath)
        #endif
    }
    // swiftlint:enable force_try

    override func url(for searchPath: SearchDirectoryPath, create: Bool = false) throws -> URL {
        let searchPathDir: FileManager.SearchPathDirectory

        switch searchPath {
        case .applicationSupportDirectory:
            searchPathDir = .applicationSupportDirectory
        case .downloadsDirectory:
            searchPathDir = .downloadsDirectory
        case .documentDirectory:
            searchPathDir = .documentDirectory
        case .cachesDirectory:
            searchPathDir = .cachesDirectory
        }

        return try self.fileManager.url(for: searchPathDir, in: .userDomainMask, appropriateFor: nil, create: create)
    }

    override func itemExists(at url: URL) -> Bool {
        return fileManager.fileExists(atPath: url.path)
    }

    override func copy(from fromURL: URL, to toURL: URL) throws {
        try self.fileManager.copyItem(at: fromURL, to: toURL)
    }

    override func move(from fromURL: URL, to toURL: URL) throws {
        try self.fileManager.moveItem(at: fromURL, to: toURL)
    }

    override func removeItem(at url: URL) throws {
        try self.fileManager.removeItem(at: url)
    }

    override func createFile(at url: URL, contents: Data?) -> Bool {
        return self.fileManager.createFile(atPath: url.path, contents: contents)
    }

    override func createDirectory(at url: URL, withIntermediateDirectories flag: Bool) throws {
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: flag)
    }

    override func readFile(at url: URL) -> Data? {
        return self.fileManager.contents(atPath: url.path)
    }
}
