#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_app_dir="$repo_root/dist/Ghostty Labels.app"
install_app_dir="$HOME/Applications/Ghostty Labels.app"
contents_dir="$build_app_dir/Contents"
macos_dir="$contents_dir/MacOS"
launch_agent="$HOME/Library/LaunchAgents/com.stainlu.ghostty-labels.plist"
rendered_launch_agent="$repo_root/.build/com.stainlu.ghostty-labels.plist"

cd "$repo_root"
mkdir -p "$repo_root/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/module-cache"
swift build --disable-sandbox -c release

mkdir -p "$macos_dir"
cp packaging/Info.plist "$contents_dir/Info.plist"
install -m 755 .build/release/ghostty-labels "$macos_dir/ghostty-labels"
codesign --force --deep --sign - "$build_app_dir"

launchctl bootout "gui/$(id -u)" "$launch_agent" >/dev/null 2>&1 || true

mkdir -p "$HOME/Applications" "$(dirname "$launch_agent")"
ditto "$build_app_dir" "$install_app_dir"
codesign --force --deep --sign - "$install_app_dir"

sed "s#__HOME__#$HOME#g" packaging/com.stainlu.ghostty-labels.plist > "$rendered_launch_agent"
install -m 644 "$rendered_launch_agent" "$launch_agent"
launchctl bootstrap "gui/$(id -u)" "$launch_agent"

echo "Installed $install_app_dir"
echo "If labels do not appear, grant Accessibility to Ghostty Labels from $HOME/Applications."
