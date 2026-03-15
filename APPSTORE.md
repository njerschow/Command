# App Store Release Checklist

## Prerequisites
- [ ] Apple Developer account ($99/year)
- [ ] App Store Connect app record created
- [ ] Bundle ID registered: `com.command.app`
- [ ] App icon: 1024x1024 PNG (no transparency, no rounded corners)

## Code Signing
```bash
# Sign with Developer ID for direct distribution
codesign --force --deep --sign "Developer ID Application: YOUR_NAME" build/Command.app

# Sign for App Store
codesign --force --deep --sign "3rd Party Mac Developer Application: YOUR_NAME" \
  --entitlements Command.entitlements build/Command.app
```

## App Store Connect Metadata
- **Name**: Command
- **Subtitle**: Terminal manager for developers
- **Category**: Developer Tools
- **Description**: See all your open terminal windows at a glance with AI-powered summaries. Command lives in your menubar and shows what's happening in every terminal — no more hunting through windows.
- **Keywords**: terminal, menubar, developer tools, command line, terminal manager
- **Privacy Policy URL**: Required (even a simple one)

## Screenshots Needed
- 1280x800 or 1440x900
- Show: popover with terminals listed, info popover, empty state

## Known App Store Review Concerns
1. **AppleScript automation**: Requires temporary exception entitlement. Apple may request justification.
2. **Spawning `claude -p`**: External process execution may need justification. Consider making AI summaries optional.
3. **LSUIElement**: Menubar-only apps are allowed but need clear functionality explanation.
4. **Network access**: Feedback endpoint + claude CLI. Document in privacy policy.

## Build & Upload
```bash
# Create pkg for App Store
productbuild --component build/Command.app /Applications build/Command.pkg \
  --sign "3rd Party Mac Developer Installer: YOUR_NAME"

# Upload via Transporter app or xcrun altool
xcrun altool --upload-app -f build/Command.pkg -t macos \
  -u "apple-id@email.com" -p "@keychain:AC_PASSWORD"
```
