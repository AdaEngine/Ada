//
//  FileSystem.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/20/23.
//

import Foundation

// TODO: Should we use this instead of NSFileManager thats dilivered by SwiftFoundation?

/// A convenient interface to the contents of the file system, and the primary means of interacting with it.
public class FileSystem: @unchecked Sendable {
    public enum SearchDirectoryPath {
        case downloadsDirectory
        case documentDirectory
        case cachesDirectory
    }

    /// The shared file manager object for the process.
    public static let `current`: FileSystem = FoundationFileSystem()

    /// Returns the path for directory where Ada app located.
    public var applicationFolderURL: URL {
        fatalErrorMethodNotImplemented()
    }

    /// Locates and optionally creates the specified common directory in a domain.
    public func url(for _: SearchDirectoryPath, create _: Bool = false) throws -> URL {
        fatalErrorMethodNotImplemented()
    }

    /// Returns a boolean value that indicates whether a file or directory exists at a specified URL.
    public func itemExists(at _: URL) -> Bool {
        fatalErrorMethodNotImplemented()
    }

    /// Creates a directory with the given attributes at the specified URL.
    public func createDirectory(at _: URL, withIntermediateDirectories _: Bool) throws {
        fatalErrorMethodNotImplemented()
    }

    /// Copies the file at the specified URL to a new location synchronously.
    public func copy(from _: URL, to _: URL) throws {
        fatalErrorMethodNotImplemented()
    }

    /// Moves the file or directory at the specified URL to a new location synchronously.
    public func move(from _: URL, to _: URL) throws {
        fatalErrorMethodNotImplemented()
    }

    /// Removes the file or directory at the specified URL.
    public func removeItem(at _: URL) throws {
        fatalErrorMethodNotImplemented()
    }

    /// Creates a file with the specified content at the given location.
    public func createFile(at _: URL, contents _: Data?) -> Bool {
        fatalErrorMethodNotImplemented()
    }

    /// Returns the contents of the file at the specified path.
    public func readFile(at _: URL) -> Data? {
        fatalErrorMethodNotImplemented()
    }
}
