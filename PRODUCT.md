# SpaceTrail

<!-- impeccable:product-schema 1 -->

## Platform

macOS

## Stack

Swift, SwiftUI, SQLite, FSEvents, and a background broker managed by macOS.

## Product Purpose

Understand what takes up space on the Mac and find files to inspect in Finder.

## Operating Context

SpaceTrail asks the user to choose disk access before the first scan and keeps the index up to date during normal use. The app opens to a sortable list of files. The Folders view lets the user browse the disk and see file and folder sizes.

## Capabilities and Constraints

The overview shows the largest files and folders alongside storage history. The broker applies changes incrementally and checks folders periodically in the background.
