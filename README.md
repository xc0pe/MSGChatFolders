# Chat folders F2

Adds folder renaming and an experimental Folder action to Messenger's native left-swipe menu. F1 filtering and the existing single-account storage key are retained.

## Install and test

Replace the F1 folder library with this build of MSGChatFoldersPrototype.dylib in ESign, keeping the original MSGPlusX and sideload patches. Do not inject both versions. Install over the same app to retain its local data.

- In Folders F2, swipe a folder and choose Rename, or open its info button and tap Rename. Membership and selection use the unchanged folder ID. Blank names are ignored.
- Swipe a conversation left. If Folder appears alongside the native actions, tap it. Confirm the picker title matches the swiped chat, then toggle its folders. Done returns to Messenger and refreshes the filter.
- Check two different chats in All chats and in a filtered folder. Check the native actions still work. Restart and check names and assignments persist.
- If Folder is absent or incorrect, export MSGChatFolders-F2.json from the folder screen after attempting a swipe. Counts and status only; no conversation or folder names/identifiers are exported.

## Integration limits

Swipe identity capture is scoped to the observed inbox binder and table while its original trailing-swipe method executes. It accepts exactly one thread key read through MSGInboxRowAdapter, matching an already decoded chat. It never guesses a chat from the row number. If Messenger does not read an unambiguous identity during menu construction, the original menu is returned unchanged. This integration needs phone validation.

Native actions, their order, and their full-swipe setting are retained; Folder is appended. Folder assignments save immediately and support multiple folders. Creating a folder in the picker requires tapping it to assign the chat.

The picker still covers loaded chats only. Permanent tabs, native long-press assignment, reordering and multiple accounts remain outside this prototype.

## Build

Run make test and make all on macOS/Xcode. CI tests compact filtering, compiles with warnings as errors, and verifies arm64 and signing. These checks do not validate Messenger runtime behavior.
