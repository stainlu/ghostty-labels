# Ghostty Labels

A tiny macOS overlay helper for Ghostty.

Ghostty does not currently expose a plugin API for custom titlebar/window UI. This helper runs beside Ghostty, watches visible Ghostty windows, and draws a small floating label on each physical Ghostty window.

On macOS, Ghostty uses native macOS tabs. Native tabs are exposed as separate windows to lower-level window APIs, so this helper groups Ghostty's tab windows by frame and renders one label for the physical window.

## Run

```sh
cd ghostty-labels
swift run ghostty-labels
```

When Ghostty is the frontmost app, the helper shows a floating badge on each visible Ghostty window.

The selected Ghostty window gets a red badge. Other visible Ghostty windows get grey badges so overlapping labels are easier to scan. When you click a badge, macOS briefly focuses the helper, but the last selected Ghostty window stays red.

Click a badge to edit the overlay label for that visible window. The label is window-wise; switching Ghostty tabs should not create another badge or change the edited label.

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
