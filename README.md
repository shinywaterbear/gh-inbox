# gh-inbox

Your open PRs, review requests, assignments and personal-repo work, inferred from
the `gh` account, in a native macOS window.

```bash
gh auth status   # the app shells out to gh
swift run        # or script/build for dist/GhInbox.app
```

It needs macOS 14 and Swift 6 (the Command Line Tools' or swift.org's).

`cmd-r` refreshes, `cmd-q` quits, and clicking a row opens it in the browser.

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
