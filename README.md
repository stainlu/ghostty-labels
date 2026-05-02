# Ghostty Labels

A tiny macOS overlay helper for Ghostty.

Ghostty does not currently expose a plugin API for custom titlebar/window UI. This helper runs beside Ghostty, watches visible Ghostty split panes through macOS Accessibility, and draws a small floating label on each split.

On macOS, Ghostty split panes are exposed in the Accessibility tree as terminal scroll areas. Lower-level window APIs only see native windows/tabs, so split-level labels require Accessibility permission for the helper.

## Run

```sh
cd ghostty-labels
swift run ghostty-labels
```

When Ghostty is the frontmost app, the helper shows a floating badge on each visible Ghostty split pane.

The selected Ghostty split gets a red badge. Other visible Ghostty splits get grey badges so overlapping labels are easier to scan. When you click a badge, macOS briefly focuses the helper, but the last selected Ghostty split stays red.

Click a badge to edit the overlay label for that visible split pane. The label is split-wise; switching Ghostty tabs should not create another badge or change the edited label.

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
scripts/install-app.sh
```

This builds `dist/Ghostty Labels.app`, installs a signed copy at `~/Applications/Ghostty Labels.app`, installs the LaunchAgent, and starts it.

After installing or rebuilding, macOS may require re-granting Accessibility permission to the freshly signed app:

1. Open System Settings > Privacy & Security > Accessibility.
2. Grant or toggle `Ghostty Labels` from `~/Applications`.
3. Restart the LaunchAgent or rerun `scripts/install-app.sh`.
