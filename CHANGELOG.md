# Release Notes

## 2026-10-01

- Disabled approval-request and interactive-question notifications on both desktop and phone by default and in startup launchers.
- Kept every-turn completion, Goal completion, interruption, and failure notifications enabled.

## 2026-09-30

- Approval requests and every normal completed response turn notify by default.
- Interactive questions and permission questions are recognized.
- Windows popups and configured Bark phone notifications are attempted independently, with the desktop popup first.
- Internal automatic-review/subagent sessions are excluded from user-facing notifications.
- Startup catch-up filters event timestamps; partially written UTF-8 JSONL records are retained until complete.
- Every local user conversation is eligible; the previous 24-session limit is removed.
- Test launchers exercise both channels. Dry-run mode sends neither channel.
- Closing a popup no longer launches Cursor automatically.

Private mobile configuration, runtime logs, and generated popup files are excluded from this release folder.
