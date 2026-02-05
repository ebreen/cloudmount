//
//  CloudMountExtension.swift
//  CloudMountExtension
//
//  @main entry point for the FSKit filesystem extension.
//  Creates and provides the filesystem delegate to FSKit.
//

import FSKit

@main
struct CloudMountExtensionMain: UnaryFileSystemExtension {
    let fileSystem = CloudMountFileSystem()
}
