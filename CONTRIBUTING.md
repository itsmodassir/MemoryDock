# Contributing to MemoryDock

Thank you for helping improve **MemoryDock**!

## Development Setup

1. Clone the repository and build locally:
   ```bash
   ./build_app.sh
   open dist/MemoryDock.app
   ```
2. Or open `Package.swift` directly in Xcode.

## Guidelines

- Keep **MemoryDock** lightweight: avoid polling heavy shell commands (`brew`, `osascript`, `du`) on short timers.
- Use Swift 6 strict concurrency cleanly (`Sendable`, `@MainActor`, `Task.detached`).
- Never delete user files without an explicit confirmation dialog or verified copy completion first.
- Keep pull requests focused on one feature or bug fix.
