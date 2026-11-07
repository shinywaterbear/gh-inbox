//! Finder and the Dock start an app with launchd's minimal environment: a PATH
//! without the user's tools and none of the `GH_*` variables a shell sets. When
//! the inherited PATH cannot find gh, gh gets the login shell's environment.

use std::env;
use std::ffi::{CStr, OsStr, OsString};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use super::capture;

/// Variables set over the inherited environment.
pub type Env = Arc<[(OsString, OsString)]>;

const MARKER: &[u8] = b"\ngh-inbox-environment\n";
/// The leading newline ends any unterminated line the rc files printed.
const COMMAND: &str = "printf '\\ngh-inbox-environment\\n'; exec /usr/bin/env -0";
const TIMEOUT: Duration = Duration::from_secs(10);

/// Only a usable answer is kept, so a slow or broken shell is retried on the
/// next refresh. The lock also keeps concurrent jobs to one shell.
static RESOLVED: Mutex<Option<Env>> = Mutex::new(None);

pub(super) fn environment() -> Env {
    let mut resolved = RESOLVED.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(env) = &*resolved {
        return env.clone();
    }
    let env: Env = if finds_gh(env::var_os("PATH").as_deref()) {
        Env::default()
    } else {
        match read(&shell(), TIMEOUT) {
            Some(vars) if finds_gh(path_of(&vars)) => vars.into(),
            _ => return Env::default(),
        }
    };
    *resolved = Some(env.clone());
    env
}

/// The account's shell, which a Finder launch does not export as `$SHELL`.
fn shell() -> PathBuf {
    // SAFETY: getpwuid returns null or a record valid until the next call,
    // and the shell string is copied out before returning.
    let from_passwd = unsafe {
        let record = libc::getpwuid(libc::getuid());
        (!record.is_null() && !(*record).pw_shell.is_null())
            .then(|| OsString::from_vec(CStr::from_ptr((*record).pw_shell).to_bytes().to_vec()))
    };
    from_passwd
        .filter(|s| !s.is_empty())
        .map_or_else(|| PathBuf::from("/bin/zsh"), PathBuf::from)
}

/// Interactive as well as login, since zsh users set PATH in `.zshrc`.
pub(super) fn read(shell: &Path, timeout: Duration) -> Option<Vec<(OsString, OsString)>> {
    let output = capture(
        Command::new(shell).args(["-l", "-i", "-c", COMMAND]),
        timeout,
    )
    .ok()?;
    output.status.success().then_some(())?;
    parse(&output.stdout)
}

/// What `env -0` printed after the marker. A segment not ended by NUL is
/// whatever the shell printed after env, not a variable.
pub(super) fn parse(stdout: &[u8]) -> Option<Vec<(OsString, OsString)>> {
    let start = stdout.windows(MARKER.len()).position(|w| w == MARKER)? + MARKER.len();
    let mut entries: Vec<&[u8]> = stdout[start..].split(|&b| b == 0).collect();
    entries.pop();
    Some(
        entries
            .into_iter()
            .filter_map(|entry| {
                let eq = entry.iter().position(|&b| b == b'=').filter(|&i| i > 0)?;
                Some((
                    OsString::from_vec(entry[..eq].to_vec()),
                    OsString::from_vec(entry[eq + 1..].to_vec()),
                ))
            })
            .collect(),
    )
}

fn path_of(vars: &[(OsString, OsString)]) -> Option<&OsStr> {
    vars.iter()
        .find(|(k, _)| k == "PATH")
        .map(|(_, v)| v.as_os_str())
}

pub(super) fn finds_gh(path: Option<&OsStr>) -> bool {
    path.is_some_and(|path| {
        env::split_paths(path).any(|dir| {
            dir.join("gh")
                .metadata()
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
    })
}
