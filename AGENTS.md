# DevKit Agent Instructions

## Scope

- DevKit is a native macOS SwiftUI application targeting macOS 15.2 or later.
- Keep changes limited to the requested feature or bug. Do not refactor unrelated simulator or image-processing code.
- Follow the existing language and naming style in each file.

## Safety

- Simulator reset, delete, recreate, and Runtime removal are destructive operations.
- Do not trigger destructive simulator actions during development or UI verification unless the user explicitly requests that exact operation.
- Preserve existing user changes in a dirty worktree.

## SwiftUI

- Read the complete view and its state owner before editing.
- Keep view state private and use the project's existing Observation and async patterns.
- Do not use forced refresh identities, artificial delays, or duplicated state updates to hide lifecycle or layout bugs.
- For native navigation and list spacing issues, fix the responsible container or environment value instead of adding compensating padding.
- In `SimulatorManagementView`, do not wrap runtime groups in `Section`. On macOS 26.5, both custom and empty section headers can reappear as a 50-80 point blank row after navigating back and reopening the screen.
- Render the runtime title and actions as a regular `List` row with explicit `listRowInsets`. Verify the first entry and at least two back-and-reopen cycles after changing this list.

## Verification

- Run `git diff --check` after edits.
- Run the macOS test suite for code changes:

  ```bash
  xcodebuild test \
    -project devkit.xcodeproj \
    -scheme devkit \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO
  ```

- For visible UI changes, launch the current Debug build and verify the actual target screen and interaction.
- State clearly when a gesture, destructive path, permission flow, or system integration was not exercised end to end.

## Git

- Use Git for inspection only unless the user explicitly asks to commit, push, create a branch, or rewrite history.
- Never discard, stash, reset, or overwrite unrelated local changes.
