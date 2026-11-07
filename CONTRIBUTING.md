# Contributing

This repository is a published copy of gh-inbox. Its history is a series of
syncs, and nothing is merged here.

- Pull requests are welcome and are read, but they are never merged or
  discussed here, and there are no replies.
- A change that is taken lands in a later sync, and its pull request is closed
  with a link to that sync. One that is not taken is closed after a while.
- Contributions are accepted under this repository's [license](LICENSE).

Accepted contributions are published through bot-authored sync commits. We
close accepted pull requests with a link to the sync containing the change.
Sync commits do not preserve contributor authorship or include contributor
credit trailers. Applicable copyright and license notices are retained.

Before sending a change, run:

```bash
cargo fmt
cargo clippy --all-targets -- -D warnings
cargo test
```
