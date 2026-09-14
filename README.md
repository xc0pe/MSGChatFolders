# MSGChatFolders diagnostics D2

A fresh diagnostic probe for the supplied Messenger 571.0.0 IPA. This is not the finished folder tweak. It identifies the running list implementation before filtering is implemented.

D2 samples up to 256 row batches, retaining a bounded history instead of stopping at the first startup row. It includes superclass metadata and counts calls to the verified row adapter's thread-key getter without recording its value.

## Build

Requires macOS with Xcode's iPhoneOS SDK. Run `make all`, or place this directory's contents at the root of a GitHub repository and run **Build folder diagnostics D2** in Actions. The workflow compiles with warnings treated as errors, checks arm64 architecture, verifies ad-hoc signing, and exports a SHA-256 checksum with the dylib. ESign must sign the final app for installation.

## One phone test

1. Start with the exact original supplied IPA. Keep its existing MSGPlusX and sideloading libraries. Do not include any previous MSGChatFolders dylib in this test.
2. Replace D1 with this `MSGChatFoldersDiagnostics.dylib` through ESign's dylib injection feature, then sign and install as usual. Include only one copy of the diagnostic library. Merely copying a dylib into Frameworks is not sufficient: the app must load it.
3. Launch Messenger. Wait up to 10 seconds for the purple **Folders · D2** button near the upper right.
4. Wait until your conversations are visible, then scroll through several screens of chats and open/close one chat.
5. Tap **Folders · D2**, then the share icon. Save/share `MSGChatFolders-D2.json` and provide it in this task.

If the button never appears, report that fact and provide the signed IPA's local path. Do not repeat the same installation multiple times. If it crashes, provide an available iOS crash report; review it for personal information before sharing. Avoid uninstalling Messenger as a troubleshooting step.

## What it collects

- App/iOS versions, probe version, hook install/call status, and implementation image filenames.
- Class names, superclass names, method signatures, and ivar names/types. No ivar values.
- Visible controller/list/delegate class names and a bounded history of those structures.
- Later row batch counts and class names (at most 128 sampled items per batch, 256 batches, 20 retained structural changes), plus a call count for the row adapter's thread-key getter. No key values are stored.

It does not collect chat names, messages, identifiers, accessibility text, screenshots, model descriptions, or database contents. The adapter hook returns its original identifier unchanged without logging or retaining it. It makes no network requests. Reports remain in memory until you use the share button, which writes one fixed report file in the app's temporary directory.

## Design safeguards and limitations

Hooks are installed only for Messenger version 571.0.0, only after runtime signature checks. Each replacement captures its own original implementation. Inherited methods receive a local override. Original arguments, return behavior and callbacks are preserved; the probe does not change rows or invoke private getters.

The status report notes whether another hook has subsequently become the current implementation; that can mean wrapping or replacement and is not proof of a conflict. Static discovery is not runtime validation. D2 still needs compilation and phone testing.

The floating button is temporary and may overlap Messenger controls. The final folder selector will use a proper layout integration. The probe's three-second UI sampling runs only while the app is active, caps traversal and stored samples, and exports no view content.

Runtime implementation references: [Apple class_addMethod](https://developer.apple.com/documentation/objectivec/class_addmethod(_:_:_:_:)) and [Apple imp_implementationWithBlock](https://developer.apple.com/documentation/objectivec/imp_implementationwithblock(_:)).
