# MSGChatFolders diagnostics D1

A fresh diagnostic probe for the supplied Messenger 571.0.0 IPA. This is not the finished folder tweak. It identifies the running list implementation before filtering is implemented.

## Build

Requires macOS with Xcode's iPhoneOS SDK. Run `make all`, or place this directory's contents at the root of a GitHub repository and run **Build folder diagnostics D1** in Actions. The workflow compiles with warnings treated as errors, checks arm64 architecture, verifies ad-hoc signing, and exports a SHA-256 checksum with the dylib. ESign must sign the final app for installation.

## One phone test

1. Start with the exact original supplied IPA. Keep its existing MSGPlusX and sideloading libraries. Do not include any previous MSGChatFolders dylib in this test.
2. Add `MSGChatFoldersDiagnostics.dylib` through ESign's dylib injection feature, then sign and install as usual. Merely copying a dylib into Frameworks is not sufficient: the app must load it.
3. Launch Messenger. Wait up to 10 seconds for the purple **Folders · D1** button near the upper right.
4. Stay on Chats, scroll the list, open and close a chat, and open then dismiss a conversation's normal long-press menu. Try its existing swipe gesture too.
5. Tap **Folders · D1**, then the share icon. Save/share `MSGChatFolders-D1.json` and provide it in this task.

If the button never appears, report that fact and provide the signed IPA's local path. Do not repeat the same installation multiple times. If it crashes, provide an available iOS crash report; review it for personal information before sharing. Avoid uninstalling Messenger as a troubleshooting step.

## What it collects

- App/iOS versions, probe version, hook install/call status, and implementation image filenames.
- Class names, superclass names, method signatures, and ivar names/types. No ivar values.
- Visible controller/list/delegate class names and a bounded history of those structures.
- One observed row batch count and up to five row object class names when the exact checked signature is available.

It does not read chat names, messages, identifiers, accessibility text, screenshots, model descriptions, or database contents. It makes no network requests. Reports remain in memory until you use the share button, which writes one fixed report file in the app's temporary directory.

## Design safeguards and limitations

Hooks are installed only for Messenger version 571.0.0, only after runtime signature checks. Each replacement captures its own original implementation. Inherited methods receive a local override. Original arguments, return behavior and callbacks are preserved; the probe does not change rows or invoke private getters.

The status report notes whether another hook has subsequently become the current implementation; that can mean wrapping or replacement and is not proof of a conflict. Static discovery is not runtime validation. D1 still needs compilation and phone testing.

The floating button is temporary and may overlap Messenger controls. The final folder selector will use a proper layout integration. The probe's three-second UI sampling runs only while the app is active, caps traversal and stored samples, and exports no view content.

Runtime implementation references: [Apple class_addMethod](https://developer.apple.com/documentation/objectivec/class_addmethod(_:_:_:_:)) and [Apple imp_implementationWithBlock](https://developer.apple.com/documentation/objectivec/imp_implementationwithblock(_:)).
