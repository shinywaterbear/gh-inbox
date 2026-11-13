# gh-inbox

Your open PRs, review requests, assignments and personal-repo work in one
native macOS window, inferred from the account the GitHub CLI is logged in as.
Nothing to configure.

## Prerequisites

- macOS 14 or later to run the app.
- Swift 6.2 or later to build it, which the Command Line Tools ship on a
  recent enough macOS (`xcode-select --install`). Check with
  `swift --version`. The core library alone builds and tests with Swift 6.0.
- To run the tests, Xcode or a toolchain from swift.org; the Command Line
  Tools aren't enough. See [Development](#development).
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

## Updating

gh-inbox checks main hourly and shows a banner when it's behind. Click it to
update, rebuild and reopen:

- **Clone or fork:** main fast-forwards to this repository's main. If yours
  has commits of its own, it's left alone and the banner says how to merge.
- **Downloaded zip:** the latest zip unpacks into a new folder beside yours
  (`gh-inbox-13`) and builds there. An app you copied elsewhere is replaced;
  one still in the old folder's `dist` stays put and the new one opens. Once
  it opens, the old folder can go.

By hand: `git pull` (or download the zip again), `script/build`, copy
`dist/GhInbox.app` over your installed copy, and reopen.

The check fetches one small file from `raw.githubusercontent.com`, without
your token.

## Using it

- The sidebar lists six queues: PRs whose author pushed since you
  reviewed them without approving, review requests asked of you by name, those that
  came through your teams, your open PRs, what's assigned to you, and
  what's left in repos you own. An item shows once, in the first queue
  that has it. `cmd-1` to `cmd-6` pick a queue; Tab, or the left and
  right arrows, move between the sidebar and the list.
- A long queue ends in "Load 25 more" and "Open on GitHub"; `cmd-l` and
  `shift-cmd-o` do the same from the keyboard.
- Your open PRs are grouped: approved, changes requested, awaiting review,
  then drafts.
- Click a row to open it in the browser, or select it with the arrow keys
  and press Return; `cmd-c` copies its link. Right-click a row to copy its
  link or `owner/repo#123` without opening it. `cmd-r` refreshes.
  It also refreshes on its own every 2 minutes while focused, every 10 in the
  background.
- Closing the window keeps gh-inbox in the Dock without fetching anything;
  click the Dock icon or press `cmd-0` to bring it back, `cmd-q` to quit.
- The All/Personal/Org tabs appear once both kinds of repository show up;
  `opt-cmd-1`/`2`/`3` pick one.

## Development

`script/check` lints, builds and tests everything, the AppKit window
included. The tests need Swift Testing, and the Command Line Tools' Swift
can't load it: with only those, `script/check` stops at
`no such module 'Testing'`. You need one of the two setups below.

**If you have Xcode** (check with `ls -d /Applications/Xcode.app`), you need
nothing else. Open Xcode once and let it finish installing its components,
then in Terminal, from the checkout:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift format --in-place --recursive Package.swift Sources Tests
script/check
```

The `export` lasts only for that Terminal window; run it again in a new one.

**If you don't have Xcode**, install swiftly, swift.org's toolchain
installer, by following [swift.org/install/macos](https://www.swift.org/install/macos/).
Then, from the checkout:

```bash
swiftly install    # installs the version named in .swift-version
swift --version    # should name that version
swift format --in-place --recursive Package.swift Sources Tests
script/check
```

If `swift --version` still names an older Swift, open a new Terminal window
so swiftly's PATH change takes effect.

Changes are checked with the toolchain named in `.swift-version`. Xcode's
`swift format` can format a few things differently; where they disagree,
that version's formatting is the one that counts.

The app's behavior lives in `Sources/GhInboxCore`, which has no AppKit and
builds and tests on Linux too; `Sources/GhInboxUI` is the AppKit window around
it and `Sources/GhInbox` the app that opens it. See [CONTRIBUTING.md](CONTRIBUTING.md) before sending a change.

## Authentication

gh-inbox uses GitHub CLI's active credentials: each refresh asks
`gh auth token` for the token, then talks to GitHub's GraphQL API directly.
`GH_HOST` picks the host, as it does for `gh`. Standard `gh auth login`
covers its needs. For classic PATs and OAuth tokens, private repositories need `repo`
and organization/team access needs `read:org`. Check with `gh auth status`; for
stored CLI credentials, add missing scopes with
`gh auth refresh -s repo,read:org`. Organization SSO may require separate token
authorization.

`GH_TOKEN` or `GITHUB_TOKEN` overrides stored credentials and must be updated
separately. Fine-grained tokens use repository access and permissions instead
of these scopes. Limited tokens may omit repositories from search results
without an error. See GitHub's [scope reference](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)
and [CLI authentication guide](https://cli.github.com/manual/gh_auth_login).

Unlike `gh`, gh-inbox's requests use the macOS network settings: they go
through the system proxy, not `HTTPS_PROXY` or `NO_PROXY`, and trust the
certificates in your keychain, not `SSL_CERT_FILE`.
