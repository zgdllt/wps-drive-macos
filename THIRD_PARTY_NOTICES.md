# Third-Party Notices

## OpenList

The original Swift application, build scripts, and documentation are licensed
under the MIT License in `LICENSE`.

The application bundles OpenList as a separate local process communicating
over authenticated loopback HTTP. Its executable is locally ad-hoc signed;
no OpenList source code has been modified.

- Project: https://github.com/OpenListTeam/OpenList
- Version: v4.2.9
- Release: https://github.com/OpenListTeam/OpenList/releases/tag/v4.2.9
- Corresponding source: https://github.com/OpenListTeam/OpenList/archive/refs/tags/v4.2.9.tar.gz
- License: GNU Affero General Public License, version 3
- License text is included inside the app at `Contents/Resources/OpenList-LICENSE`.
- Corresponding source is included inside the same app at
  `Contents/Resources/OpenList-v4.2.9-source.tar.gz`, including the upstream
  build files, `go.mod`, and `go.sum`. Consult the source archive's README and
  build workflow for upstream build instructions and required dependencies.
- Downloaded artifact: `openlist-darwin-arm64-lite.tar.gz`
- SHA-256: `a4241527f1f74e786ec33accb3cebc7008ea1ba5717a462b0af23a1ac6565e88`
- Source archive SHA-256:
  `a762ff50b71b384f03af2996cac2aba471b0d5ec44aad0255e646a41c8af7f49`

Both original archives are verified before extraction and local signing.

## Apple Interface Symbols

In-app buttons, the window header, and the menu bar use SF Symbols supplied by
macOS. At the user's request, `scripts/RenderIcon.swift` also exports
`externaldrive.badge.icloud` in red for the application and File Provider
bundle icons. This symbol is Apple's artwork and is not covered by this
project's MIT License. Consult Apple's separate usage terms before public
distribution or trademark use.

- SF Symbols guidance and usage terms:
  https://developer.apple.com/design/human-interface-guidelines/sf-symbols

## WPS and SeaDrive

SeaDrive is used only as a documented user experience reference. This project
does not bundle or modify SeaDrive code, binaries, configuration, or user data.

WPS, Kingsoft, Seafile, and SeaDrive names and marks belong to their respective
owners. This is an independent, unofficial client and is not endorsed by them.
