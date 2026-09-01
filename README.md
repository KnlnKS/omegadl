<div align="center">

<img src="docs/logo.png" alt="OmegaDL" width="128" height="128">

# OmegaDL

An unofficial native macOS client for MEGA downloads and uploads.

</div>

## Install

Requires macOS 26 or later.

Download the latest zip from [Releases](https://github.com/KnlnKS/omegadl/releases/latest), unzip, drag `OmegaDL.app` into Applications. Then clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/OmegaDL.app
```

Builds are not signed with an Apple Developer ID, so macOS blocks the app until you run that.

## What it does

- Paste a file or folder link, pick what you want, download it. No account needed.
- Sign in to browse your own account, upload by dropping files onto the window, move things to the rubbish bin or put them back.
- Each file downloads over several connections at once, eight by default and up to sixteen. Quit mid-transfer and it picks up where it stopped.
- OmegaDL derives your keys and decrypts files locally. Only the session token is kept, in the Keychain.

## Build it yourself

```sh
brew install xcodegen
swift test --package-path MegaKit
xcodegen generate
open OmegaDL.xcodeproj
```

`MegaKit` is the Swift package that talks to MEGA: login, RSA and AES key handling, chunked transfers with MAC verification. The app target is SwiftUI on top of it.

## Thanks

[qgustavor/mega](https://github.com/qgustavor/mega) was a great resource while developing this.

## License

[MIT](LICENSE).

## Not affiliated with MEGA

OmegaDL is unofficial. It is not affiliated with, endorsed by, or connected to MEGA Limited, and MEGA is their trademark. Use it at your own risk and stay within MEGA's terms of service.
