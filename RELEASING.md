# Command — Release Process

## Prerequisites
- `gh` CLI authenticated (`gh auth status`)
- All changes committed and pushed to `main`
- All tests passing (`make test`)

## Steps

### 1. Bump version
Edit `Info.plist` — update both version fields:
```xml
<key>CFBundleVersion</key>
<string>2</string>           <!-- increment build number -->
<key>CFBundleShortVersionString</key>
<string>1.1.0</string>       <!-- new semver -->
```

### 2. Commit the version bump
```bash
git add Info.plist
git commit -m "Bump version to 1.1.0"
git push origin main
```

### 3. Build the distributable
```bash
make dist
```
This creates `build/Command.zip` containing `Command.app` with the correct Info.plist.

### 4. Create the GitHub release
```bash
gh release create v1.1.0 build/Command.zip \
  --title "Command v1.1.0" \
  --notes "$(cat <<'EOF'
## What's New

<video src="https://URL_TO_VIDEO.mp4"></video>

- Feature description
- Bug fix description

## Install
Download `Command.zip`, unzip, move to `/Applications`, launch.

If macOS says the app is damaged, run:
\`\`\`
xattr -cr /Applications/Command.app
\`\`\`
EOF
)"
```

**Release notes format:**
- Start with `## What's New`
- If you have a demo video, add it as: `<video src="URL"></video>` right after the heading
  - Upload the video to a GitHub issue/comment first to get a `github.com/user-attachments/assets/...` URL
  - Or use a raw `.mp4`/`.mov` URL on its own line
- The app's update popover will show the video + notes when a user hovers "update available"
- End with install instructions for new users

### 5. Verify
```bash
# Check the API returns the new release
curl -s "https://api.github.com/repos/njerschow/Command/releases/latest" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'tag: {d[\"tag_name\"]}, assets: {len(d.get(\"assets\",[]))}')"
```

Then relaunch the OLD version of Command — the footer should show "v1.1.0 available" in blue. Clicking it opens a popover with the release notes and video.

## Version scheme
- **Major** (2.0.0): breaking changes or major rewrites
- **Minor** (1.1.0): new features
- **Patch** (1.0.1): bug fixes only

## How update detection works
- `UpdateChecker.swift` calls `GET /repos/njerschow/Command/releases/latest` on app launch and each popover open (rate-limited to 1 check/hour)
- Compares remote tag version against `CFBundleShortVersionString` from Info.plist
- If newer: shows blue "v{version} available" in footer
- Clicking opens a popover with release notes, video preview (if present), and download/GitHub links
- The `.zip` asset download URL is pulled from the release's `assets` array
