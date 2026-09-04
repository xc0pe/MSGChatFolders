# MSGChatFolders

**Organize your Messenger conversations into custom folders.**

A lightweight injectable tweak for Facebook Messenger (v576.0.0) that adds a local folder system — create folders like "Work", "University", "Friends", and assign conversations to them. All data is stored locally; Messenger's backend is untouched.

---

## Features

- **Create custom folders** — tap the "+" button in the folder tab bar
- **Assign conversations** — long-press (1 second) a conversation to add it to a folder
- **Filter by folder** — tap a folder tab to show only its conversations
- **Rename/delete folders** — long-press a folder tab
- **Dark mode support** — adapts to Messenger's theme
- **Persistent** — folder assignments survive app restarts
- **Non-invasive** — doesn't modify Messenger's data or servers

---

## Setup Guide (Step by Step)

### Option A: Using GitHub Actions (Recommended — No Tools Needed)

1. **Create a GitHub account** (if you don't have one): https://github.com/signup

2. **Create a new private repository:**
   - Go to https://github.com/new
   - Name: `MSGChatFolders`
   - Set to **Private**
   - Click **Create repository**

3. **Upload the source code:**
   - Click **"uploading an existing file"** on the repo page
   - Drag and drop ALL files from the `MSGChatFolders` folder:
     - `MSGChatFolders_main.m`
     - `MSGChatFolderManager.h`
     - `MSGChatFolderManager.m`
     - `MSGChatFolderTabView.h`
     - `MSGChatFolderTabView.m`
     - `MSGChatFolderHooks.m`
     - `Makefile`
   - Also upload the `.github/workflows/build.yml` file
     (you may need to create the `.github/workflows/` folder structure)
   - Click **Commit changes**

4. **Wait for the build:**
   - Go to the **Actions** tab in your repository
   - You should see "Build MSGChatFolders" running
   - Wait for it to complete (usually 1-2 minutes)
   - Click on the completed run → **Artifacts** → Download `MSGChatFolders-dylib`
   - This ZIP contains your compiled `MSGChatFolders.dylib`

5. **Inject into Messenger IPA:**
   - See "Injection" section below

### Option B: Build Locally on macOS

```bash
# Requires Xcode command line tools
xcode-select --install

# Clone and build
cd MSGChatFolders
make

# Output: build/MSGChatFolders.dylib
```

---

## Injection

### Method 1: Sideloadly (Windows/macOS — Easiest)

1. Download [Sideloadly](https://sideloadly.io/)
2. Open Sideloadly
3. Drag the **decrypted Messenger IPA** into Sideloadly
4. Click **Advanced Options** → **Inject Dylibs/Frameworks**
5. Add `MSGChatFolders.dylib`
6. Enter your Apple ID / certificate
7. Click **Start** — Sideloadly will inject, sign, and install

### Method 2: Esign (iPhone — No Computer)

1. Transfer both the **Messenger IPA** and `MSGChatFolders.dylib` to your iPhone
2. Open Esign → **Import** the IPA
3. Tap on the IPA → **Inject** → select `MSGChatFolders.dylib`
4. Sign and install

### Method 3: Python Script (Advanced — Any OS)

```bash
# Install LIEF (Python library for Mach-O patching)
pip install lief

# Run the injection script
python scripts/inject.py \
    "com.facebook.Messenger_576.0.0_und3fined.ipa" \
    "build/MSGChatFolders.dylib" \
    "Messenger_Folders.ipa"

# Then sign Messenger_Folders.ipa with your certificate
```

---

## How to Use

1. **Open Messenger** — you'll see a folder tab bar above your conversations:
   ```
   [All] [+]
   ```

2. **Create a folder** — tap **+**, enter a name (e.g., "Work")

3. **Assign a conversation** — **long-press** (hold for 1 second) on any conversation → tap **"📁 Add to Folder"** → select a folder

4. **View a folder** — tap the folder tab to filter conversations

5. **Manage folders** — **long-press** a folder tab to rename or delete it

---

## Troubleshooting

### "Folder tabs don't appear"
- Check Messenger's console logs for `[MSGChatFolders]` messages
- The tweak logs all discovered Messenger class names at startup
- If no inbox class is found, the class names may have changed in your Messenger version

### "Long-press doesn't show folder menu"
- The tweak uses a **1-second** long-press (longer than Messenger's default) to avoid conflicts
- Make sure you're pressing on a **conversation cell**, not a header or empty space

### "Conversations aren't being filtered"
- Folder filtering depends on extracting thread keys from conversation cells
- Check console logs for "WARNING: Could not extract threadKey" messages
- If thread key extraction fails, it means Messenger's internal class structure differs from what we expected — this will need updating

### How to view console logs
- On macOS: Open **Console.app** → filter for `MSGChatFolders`
- Alternative: Use [Consolation](https://eclecticlight.co/consolation/) or Xcode's Devices window

---

## Architecture

```
MSGChatFolders.dylib
├── MSGChatFolders_main.m      — Entry point (constructor)
├── MSGChatFolderManager.h/m   — Folder data model & persistence
├── MSGChatFolderTabView.h/m   — Folder tab bar UI
└── MSGChatFolderHooks.m       — Runtime hooks & swizzling
```

### How it works
1. When Messenger launches, `dyld` loads our dylib automatically
2. The `__attribute__((constructor))` function runs, registering method swizzles
3. `MSGInboxViewController.viewDidAppear:` is hooked to inject the folder tab bar
4. A custom long-press gesture recognizer is added to the conversation list
5. Thread keys are extracted from conversation cells using multiple fallback strategies
6. Folder assignments are stored in `NSUserDefaults` (independent of Messenger's data)

---

## Version Compatibility

| Messenger Version | Status |
|---|---|
| v576.0.0 | ✅ Primary target |
| Other versions | ⚠️ May work, may need class name updates |

> **Note:** Messenger updates frequently and class names can change. If the tweak stops working after a Messenger update, the hooks in `MSGChatFolderHooks.m` may need to be updated with new class names.

---

## License

This tweak is for personal use only. Not affiliated with or endorsed by Meta.
