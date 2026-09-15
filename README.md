# Chat folders F1 — functional prototype

Targets the supplied Messenger 571.0.0 installation with one account. This build supports creating folders, manually assigning currently loaded chats, deleting folders, and selecting a folder to filter Messenger's native list. Membership persists locally across restarts. The app starts in All chats.

## Install and try

1. Use the original supplied IPA, keeping MSGPlusX and its original sideloading patches. Remove the D1/D2 diagnostic library and any old folder tweak from your injection selection.
2. Inject only `MSGChatFoldersPrototype.dylib` as the new folder tweak, then sign/install with ESign as before.
3. Once chats load, tap **Folders · F1**. Tap **+** to create a folder. Tap its **ⓘ** button and select two or three recognizable chats. Go back and tap the folder's name to apply it.
4. Check that those chats appear consecutively and each opens the correct conversation. Use **All chats** to restore the full list. Test receiving a message and restarting Messenger; membership should remain saved.
5. If selection has no effect, rows are missing, or controls say they are waiting for models, share `MSGChatFolders-F1.json` using the share button in the folder screen. The report contains counts, class names and status, not chat names, identifiers or folder names.

The picker shows only chats Messenger has loaded. To assign older chats, select All chats, scroll further in Messenger, then reopen the picker. This is not an account-wide database query.

## Limits

This is the first functional prototype and requires phone validation. Native long-press assignment, a permanent tab strip, rename/reordering, account switching, and comprehensive pagination testing are not implemented yet. The temporary F1 button uses the same upper-right location as diagnostics.

Filtering is scoped to the observed inbox data-source instance and runs on the main thread. It returns an ordered subset of the original row objects to Messenger's renderer; it never hides cells or changes row heights. Unknown conversation identities disable filtering rather than dropping those chats. It does not modify Messenger's database or send network requests.

There is still a runtime assumption to verify: the row wrapper's `inboxModel` must be the known row adapter, a compatible typed model, or MBQThreadListModel accepted by the known adapter initializer. The probe reports the encountered class if this path is unsupported.

Folders and thread-key memberships are stored in this app's own NSUserDefaults under a separate key for this single-account prototype. It does not import or overwrite old tweak data. Removing a folder removes only its local assignments.

## Build

On macOS with Xcode, run `make test` and `make all`. The workflow runs Foundation-based filter tests, compiles the iOS arm64 dylib with warnings as errors, checks architecture, verifies ad-hoc signing, and produces a checksum. Compilation and tests do not prove runtime integration, rendering or MSGPlusX compatibility.
