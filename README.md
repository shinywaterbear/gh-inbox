# gh-inbox

Your open PRs, review requests, assignments and personal-repo work in one
native macOS window, inferred from the account the GitHub CLI is logged in as.
Nothing to configure.

## Prerequisites

- macOS 14 or later to run the app.
- Swift 6.2 or later to build it, which the Command Line Tools ship on a
  recent enough macOS (`xcode-select --install`). Check with
  `swift --version`. The core library alone builds and tests with Swift 6.0.
- The [GitHub CLI](https://cli.github.com), logged in: `gh auth status`. See
  [Authentication](#authentication) for the scopes it needs.

## Build and install

```bash
script/build                          # builds dist/GhInbox.app
cp -R dist/GhInbox.app /Applications/
open /Applications/GhInbox.app
```

Any folder works; `~/Applications` keeps it to your account and needs no admin
rights.

A copy built on your own Mac opens without Gatekeeper prompts. Launched from
Finder or the Dock, it finds `gh` through your login shell's PATH.

For a quick look without installing, `swift run` starts it from the checkout.

## Using it

- Sections: awaiting your review, your open PRs, assigned to you, and what's
  left in repos you own. An item shows once, in the first section that has it.
- Click a row to open it in the browser. `cmd-r` refreshes and `cmd-q` quits.
  It also refreshes on its own every 2 minutes while focused, every 10 in the
  background.
- "Direct only" hides review requests that reached you through a team. The
  All/Personal/Org tabs appear once both kinds of repository show up.

## Development

`script/check` lints, builds and tests everything, the AppKit window
included. It needs the swift.org toolchain named in `.swift-version`; the
Command Line Tools' Swift has no Swift Testing.

```bash
swift format --in-place --recursive Package.swift Sources Tests
script/check
```

The app's behavior lives in `Sources/GhInboxCore`, which has no AppKit and
builds and tests on Linux too; `Sources/GhInbox` is the AppKit window around
it. See [CONTRIBUTING.md](CONTRIBUTING.md) before sending a change.

## Authentication

gh-inbox uses GitHub CLI's active credentials. Standard `gh auth login` covers
its needs. For classic PATs and OAuth tokens, private repositories need `repo`
and organization/team access needs `read:org`. Check with `gh auth status`; for
stored CLI credentials, add missing scopes with
`gh auth refresh -s repo,read:org`. Organization SSO may require separate token
authorization.

`GH_TOKEN` or `GITHUB_TOKEN` overrides stored credentials and must be updated
separately. Fine-grained tokens use repository access and permissions instead
of these scopes. Limited tokens may omit repositories from search results
without an error. See GitHub's [scope reference](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)
and [CLI authentication guide](https://cli.github.com/manual/gh_auth_login).
