# tetheriOS

Native SwiftUI iOS app that connects directly to GitHub and renders your markdown vault.

## Features

- One-time onboarding for GitHub owner/repo/branch/token
- Token stored in Keychain
- Direct GitHub API sync (no Next.js dependency)
- Folder tree + file browser for markdown notes
- Obsidian wikilink conversion (`[[link]]`)
- Internal markdown note link navigation
- Frontmatter parsing (YAML block + `Key:: value` style)
- Search by note name
- Restore last opened note
- Auto-refresh when app returns to foreground

## Setup

1. Open `tetheriOS.xcodeproj` in Xcode.
2. Run the app.
3. On first launch, complete onboarding:
   - GitHub owner
   - GitHub repository
   - Optional branch (leave blank to use default branch)
   - Personal access token

## GitHub token scopes

- Private repo: `repo`
- Public repo: `public_repo`

## Notes

- No backend server is required.
- Use Settings -> Reset Connection to re-run onboarding.
