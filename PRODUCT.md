# SpaceTrail

<!-- impeccable:product-schema 1 -->

## Platform

macOS and Windows

## Stack

Swift, SwiftUI, and FSEvents on macOS. Rust, WebView2, and directory-change notifications on Windows. A local SQLite index supports both desktop apps.

## Product Purpose

Understand what fills a computer’s storage and find files to inspect in Finder or Explorer.

## Operating Context

SpaceTrail indexes locations it can read and keeps the index up to date during normal use. The app opens to a sortable list of files. Files and Search offer file type and minimum on-disk size filters. The Folders view lets the user browse the disk and compare file and folder sizes.

## Capabilities and Constraints

The overview shows the largest files and folders alongside storage history. The broker applies changes incrementally and checks folders periodically in the background.
