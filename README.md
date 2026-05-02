# Ghostty Labels

A tiny macOS overlay helper for Ghostty.

Ghostty does not currently expose a plugin API for custom titlebar/window UI. This helper runs beside Ghostty, watches visible Ghostty windows, and draws a small floating label on each window using the window/tab title.

## Run

```sh
cd ghostty-labels
swift run ghostty-labels
```

Set a Ghostty tab title with `cmd+ctrl+l`. When Ghostty is the frontmost app, the helper shows that title as a floating badge on each visible Ghostty window.

The active Ghostty window gets a red badge. Other visible Ghostty windows get grey badges so overlapping labels are easier to scan.

Click a badge to edit the overlay label for that visible window. Choose `Use Tab Title` to clear the custom overlay label and follow Ghostty's title again.

Stop it with `ctrl+c`.

## Options

Environment variables:

```sh
GHOSTTY_LABEL_POSITION=top-right swift run ghostty-labels
GHOSTTY_LABEL_POSITION=top-left swift run ghostty-labels
GHOSTTY_LABEL_POSITION=top-center swift run ghostty-labels
GHOSTTY_LABEL_ALWAYS=1 swift run ghostty-labels
```

By default labels only show while Ghostty is frontmost, so they do not cover other apps.

## Install Locally

```sh
swift build -c release
install -m 755 .build/release/ghostty-labels ~/.local/bin/ghostty-labels
```

Run it in the background from any terminal:

```sh
ghostty-labels
```
