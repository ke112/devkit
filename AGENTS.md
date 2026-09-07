# DevKit Agent Instructions

## Scope and Authorization

- DevKit is a native macOS SwiftUI application targeting macOS 15.2 or later.
- Keep changes within the request and follow each file's language and naming style. Read [CONTEXT.md](CONTEXT.md) when working on image-processing behavior or terminology.
- Analysis and review requests are read-only. Change requests authorize scoped local edits and non-destructive verification; complete that work without repeated confirmation. Ask only when missing information materially affects correctness, scope, or authorization, and continue independent authorized work.
- External writes, destructive operations, and Git mutations require explicit authorization covering the action and target. Reuse authorization already given in the session; otherwise prepare a reviewable result before asking. Preserve unrelated user changes.
- Simulator reset, delete, recreate, and Runtime removal require an explicit request for that exact operation, including during UI verification.
- User instructions take precedence over skill guidance, subject to higher-priority instructions. If a skill blocks requested work or requires confirmation, link the exact file, quote the rule, and explain its applicability.

## Scripts

- Keep reusable automation in standalone `*.py` or `*.sh` files with entry points, arguments, and usage/help text so it can be exported and run independently.
- Do not embed multi-step script logic in application code, UI callbacks, or build configuration. A `Process` invocation may only launch a standalone script or a single system command.

## SwiftUI

- Read the complete view and state owner before editing; keep view state private and preserve the module's existing state-management and async patterns.
- Do not use forced refresh identities, artificial delays, or duplicated state updates to hide lifecycle or layout bugs.
- For native navigation and list spacing issues, fix the responsible container or environment value instead of adding compensating padding.
- In `SimulatorManagementView`, do not wrap runtime groups in `Section`. On macOS 26.5, both custom and empty section headers can reappear as a 50-80 point blank row after navigating back and reopening the screen.
- Render the runtime title and actions as a regular `List` row with explicit `listRowInsets`. Verify the first entry and at least two back-and-reopen cycles after changing this list.

## Verification

- Inspect the diff and run `git diff --check` after edits. For documentation-only changes, check instruction consistency, referenced paths, and preservation of business and authorization constraints; no app build is required.
- Run the macOS test suite for code changes:

  ```bash
  xcodebuild test \
    -project devkit.xcodeproj \
    -scheme devkit \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO
  ```

- For visible UI changes, launch the current Debug build and verify the actual target screen and interaction.
- Once required checks pass, repeat or broaden them only for new changes, failures, or unresolved risks.
- Report changed files, commands and results, and remaining unverified behavior concisely. Identify gestures, destructive paths, permission flows, and system integrations that were not exercised when relevant to the change.
