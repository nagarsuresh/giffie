## Giffie — screen to animated GIF, right from the menu bar

**Download `Giffie-<version>.dmg` below**, open it and drag **Giffie** into **Applications**.

### First launch
This build is ad-hoc signed, not notarized by Apple, so macOS blocks the first launch:

- **macOS 15 Sequoia and later:** open Giffie once, click **Done** in the warning, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to Giffie.
- **macOS 13–14:** right-click (or Control-click) Giffie in Applications, choose **Open**, then click **Open** again.
- Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Giffie.app`

On first launch, Giffie asks **where to save your GIFs**, then asks for **Screen Recording** permission (System Settings → Privacy & Security → Screen Recording). Relaunch Giffie after you allow it.

### How to record
1. Click the Giffie icon in the menu bar → **Record**, or press **⌥⇧⌘G** from anywhere.
2. Drag over the area you want (or click a window to snap to it). Use the handles to adjust it.
3. Press **Space** (or click **Record**) to start. Press **Space**, **Esc**, the menu bar icon or **Stop** to finish.
4. The GIF shows up in the menu bar list. **Drag it into any app** (Slack, Mail, GitHub, Finder…) or copy it.

Recordings stop automatically at **30 seconds** or **10 MB**, whichever comes first (you can change both in Settings). The size limit is exact: a saved GIF never grows past it.

Requires macOS 13 Ventura or later. Universal build for Apple Silicon and Intel Macs.
