//! Everything is inferred from the account `gh` is logged in as: no owner,
//! org or team names are configured. `review-requested:@me` matches requests
//! made to you and to your teams, so no team lookup is needed.

use std::ffi::OsString;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::Value;

mod login;

const ITEMS: &str = include_str!("github/items.graphql");
const REQUESTS: &str = include_str!("github/requests.graphql");
const CHECKS: &str = include_str!("github/checks.graphql");

pub struct SectionSpec {
    alias: &'static str,
    pub name: &'static str,
    scope: &'static str,
    /// Who the section is about.
    qualifier: &'static str,
}

/// Display order.
pub const SECTIONS: [SectionSpec; 4] = [
    SectionSpec {
        alias: "review",
        name: "Awaiting my review",
        scope: "is:open is:pr archived:false",
        qualifier: "review-requested:@me",
    },
    SectionSpec {
        alias: "authored",
        name: "My open PRs",
        scope: "is:open is:pr archived:false",
        qualifier: "author:@me",
    },
    SectionSpec {
        alias: "assigned",
        name: "Assigned to me",
        scope: "is:open archived:false",
        qualifier: "assignee:@me",
    },
    SectionSpec {
        alias: "personal",
        name: "Also in my repos",
        scope: "is:open archived:false",
        qualifier: "user:@me",
    },
];

pub const REVIEW_SECTION: usize = 0;

/// Never matches a request that reached the viewer through a team.
const DIRECT_REVIEW_QUALIFIER: &str = "user-review-requested:@me";

/// Makes the first page the newest activity.
const ORDER: &str = "sort:updated-desc";

/// The search a section runs; `direct_only` narrows only the review section.
pub fn search(section: usize, direct_only: bool) -> String {
    let spec = &SECTIONS[section];
    let qualifier = if section == REVIEW_SECTION && direct_only {
        DIRECT_REVIEW_QUALIFIER
    } else {
        spec.qualifier
    };
    format!("{} {qualifier} {ORDER}", spec.scope)
}

/// What a section's search says about how each PR's review request
/// reached the viewer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Routing {
    NotAsked,
    AllDirect,
    FromRequests,
}

impl Routing {
    fn of(section: usize, direct_only: bool) -> Self {
        match (section == REVIEW_SECTION, direct_only) {
            (false, _) => Routing::NotAsked,
            (true, true) => Routing::AllDirect,
            (true, false) => Routing::FromRequests,
        }
    }
}

/// Identity plus one section's newest `size` matches. Every request names
/// the viewer, so results from two accounts are never combined.
fn section_query(alias: &str, search: &str, size: u32, routing: Routing) -> String {
    let (requests, fragment) = match routing {
        Routing::FromRequests => (" nodes { ...requests }", REQUESTS),
        Routing::NotAsked | Routing::AllDirect => ("", ""),
    };
    format!(
        "query {{\n  viewer {{ login url }}\n  {alias}: search(query: \"{search}\", type: ISSUE, first: {size}) {{ ...items{requests} }}\n}}\n\n{ITEMS}{fragment}"
    )
}

/// Identity plus whether the viewer belongs to any organization. A second
/// `viewer` alias keeps the identity decodable on its own.
const MEMBERSHIP_QUERY: &str = "query {\n  viewer { login url }\n  memberships: viewer { organizations(first: 1) { totalCount } }\n}\n";

/// Token scopes that let `organizations` include private memberships.
const ORG_SCOPES: [&str; 3] = ["read:org", "write:org", "admin:org"];

/// Identity plus the check state of each PR id.
fn checks_query(ids: &[String]) -> String {
    let ids = serde_json::to_string(ids).expect("strings serialize");
    format!(
        "query {{\n  viewer {{ login url }}\n  nodes(ids: {ids}) {{ __typename ...checks }}\n}}\n\n{CHECKS}"
    )
}

/// The same search on GitHub, for everything a section can't show.
pub fn search_url(section: usize, host: &str, direct_only: bool) -> String {
    format!(
        "https://{host}/search?type=issues&q={}",
        encode(&search(section, direct_only))
    )
}

/// gh's documented exit status when it has no credentials.
const EXIT_AUTH_REQUIRED: i32 = 4;
/// Go net error text gh passes through when no HTTP response arrived.
const NETWORK_MARKERS: &[&str] = &[
    "dial tcp",
    "no such host",
    "connection refused",
    "i/o timeout",
    "tls handshake",
];
/// GitHub's wording when a request outran its processing deadline, which it
/// may also answer with a bare 502 or 504.
const SERVER_MARKERS: &[&str] = &[
    "http 502",
    "http 503",
    "http 504",
    "502 bad gateway",
    "503 service unavailable",
    "504 gateway timeout",
    "this may be the result of a timeout",
];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    #[error("gh is not installed or not on PATH")]
    NotInstalled,
    #[error("gh is not logged in")]
    NotLoggedIn,
    #[error("gh's token was rejected: {0}")]
    BadCredentials(String),
    #[error("GitHub denied access: {0}")]
    Forbidden(String),
    #[error("GitHub refused this network: {0}")]
    IpRestricted(String),
    #[error("GitHub had a server error: {0}")]
    Server(String),
    #[error("GitHub rate limit reached: {0}")]
    RateLimited(String),
    #[error("could not reach GitHub: {0}")]
    Network(String),
    #[error("gh did not finish within {}s", .0.as_secs())]
    Timeout(Duration),
    #[error("could not run gh: {0}")]
    Spawn(String),
    #[error("gh failed: {0}")]
    Gh(String),
    #[error("unexpected gh output: {0}")]
    Parse(String),
    #[error("GitHub withheld {0} item(s), usually because of SSO")]
    Withheld(usize),
    #[error("{0} item(s) could not be read")]
    Unreadable(usize),
    #[error("GitHub's checks describe a different commit than the list")]
    OtherCommit,
}

impl Error {
    pub fn hint(&self) -> Option<&'static str> {
        Some(match self {
            Error::NotInstalled => {
                "Install the GitHub CLI and put it on your login shell's PATH, then refresh."
            }
            Error::NotLoggedIn => "Run `gh auth login`, then refresh.",
            Error::BadCredentials(_) => "Run `gh auth login` to replace the token.",
            Error::Forbidden(_) | Error::Withheld(_) => {
                "Check `gh auth status`: classic/OAuth tokens need `repo` for private repositories \
                 and `read:org` for organization/team access. SSO organizations may require token \
                 authorization. If using `GH_TOKEN` or `GITHUB_TOKEN`, check that token instead."
            }
            Error::IpRestricted(_) => {
                "Connect to a network the organization allows, such as its VPN, then refresh."
            }
            Error::Server(_) => {
                "Usually temporary or a slow query; refresh to retry, or load fewer results."
            }
            Error::RateLimited(_) => "Wait a minute, then refresh.",
            Error::Network(_) | Error::Timeout(_) => "Check the network or proxy, then refresh.",
            Error::OtherCommit => "The PR probably changed between requests; refresh.",
            Error::Spawn(_) | Error::Gh(_) | Error::Parse(_) | Error::Unreadable(_) => {
                return None;
            }
        })
    }

    /// The error and its hint as sentences. GitHub's messages often end in a
    /// period already.
    pub fn describe(&self) -> String {
        let text = self.to_string();
        let text = text.trim_end_matches('.');
        match self.hint() {
            Some(hint) => format!("{text}. {hint}"),
            None => format!("{text}."),
        }
    }

    fn from_failure(status: ExitStatus, stderr: &[u8]) -> Self {
        if status.code() == Some(EXIT_AUTH_REQUIRED) {
            return Error::NotLoggedIn;
        }
        Self::classify(None, &String::from_utf8_lossy(stderr))
    }

    /// `kind` is a GraphQL error's `type`, when the error came in a response.
    fn classify(kind: Option<&str>, message: &str) -> Self {
        let message = message.split_whitespace().collect::<Vec<_>>().join(" ");
        let lower = message.to_ascii_lowercase();
        if kind == Some("RATE_LIMITED") || lower.contains("rate limit") {
            Error::RateLimited(message)
        } else if lower.contains("http 401") || lower.contains("401 unauthorized") {
            Error::BadCredentials(message)
        } else if lower.contains("ip allow list") {
            Error::IpRestricted(message)
        } else if kind == Some("FORBIDDEN")
            || lower.contains("http 403")
            || lower.contains("403 forbidden")
            || lower.contains("saml")
        {
            Error::Forbidden(message)
        } else if NETWORK_MARKERS.iter().any(|m| lower.contains(m)) {
            Error::Network(message)
        } else if SERVER_MARKERS.iter().any(|m| lower.contains(m)) {
            Error::Server(message)
        } else {
            Error::Gh(message)
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Checks {
    Passing,
    Failing,
    Pending,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Review {
    Approved,
    ChangesRequested,
    Required,
}

#[derive(Debug, Clone)]
pub struct Item {
    /// GitHub's node id, which check lookups use.
    pub id: String,
    pub number: u64,
    pub title: String,
    pub repository: Repository,
    pub is_pull_request: bool,
    pub is_draft: bool,
    /// The PR's head commit; `None` for issues.
    pub head: Option<String>,
    pub review: Option<Review>,
    /// How the review request reached the viewer; review section only.
    pub review_route: Option<ReviewRoute>,
    pub url: String,
    /// Bumped by any activity: creation, comments, pushes, reviews, labels.
    pub updated_at: String,
    pub author: String,
}

impl Item {
    pub fn owner(&self) -> &str {
        self.repository
            .name_with_owner
            .split_once('/')
            .map_or("", |(owner, _)| owner)
    }

    /// 0 needs attention, 1 approved, 2 draft.
    fn tier(&self) -> u8 {
        if self.is_draft {
            2
        } else if self.review == Some(Review::Approved) {
            1
        } else {
            0
        }
    }
}

/// A team is named only when it is the one request that can explain the
/// match; anything withheld or cut off leaves the route unknown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReviewRoute {
    Direct,
    Team(String),
    /// One of several requested teams, unknown which.
    SomeTeam,
    Unknown,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Repository {
    pub name: String,
    pub name_with_owner: String,
    pub owner: Option<Owner>,
}

impl Repository {
    /// `Unknown` when GitHub didn't return an owner type: left out of both
    /// the personal and organization filters rather than guessed into one.
    pub fn owner_kind(&self) -> OwnerKind {
        match self.owner.as_ref().map(|o| o.typename.as_str()) {
            Some("User") => OwnerKind::Personal,
            Some("Organization") => OwnerKind::Organization,
            _ => OwnerKind::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OwnerKind {
    Personal,
    Organization,
    Unknown,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Owner {
    #[serde(rename = "__typename")]
    pub(crate) typename: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    pub login: String,
    /// The GitHub host gh is talking to, e.g. `github.com`.
    pub host: String,
}

/// What one section's search returned.
#[derive(Debug, Clone)]
pub struct Page {
    pub items: Vec<Item>,
    /// GitHub's match count.
    pub total: u64,
    /// GitHub has more matches than the page fetched.
    pub truncated: bool,
    /// Results GitHub returned on the page, before dropping unreadable or
    /// withheld ones.
    pub returned: usize,
}

#[derive(Debug, Clone)]
pub struct SectionFetch {
    /// Who answered; `None` when no usable response arrived.
    pub identity: Option<Identity>,
    pub page: Result<Page, Error>,
    /// Why some items are missing or incomplete, even though others loaded.
    pub warnings: Vec<Error>,
}

/// A PR's check state, for the head commit it describes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckState {
    pub head: String,
    /// `None` when the commit has no checks.
    pub checks: Option<Checks>,
}

/// Whether the viewer belongs to any organization.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Membership {
    Member,
    /// An empty list from a token that can see private memberships.
    None,
    /// Failed, partial, or from a token that may not see every membership.
    Unknown,
}

#[derive(Debug, Clone)]
pub struct MembershipFetch {
    pub identity: Option<Identity>,
    pub membership: Membership,
}

#[derive(Debug, Clone)]
pub struct ChecksFetch {
    pub identity: Option<Identity>,
    /// One entry per requested id, in request order.
    pub results: Vec<(String, Result<CheckState, Error>)>,
}

/// The gh executable, variables set over the inherited environment, and how
/// long a call may take, output included.
#[derive(Debug, Clone)]
pub struct Gh {
    program: OsString,
    env: login::Env,
    timeout: Duration,
}

impl Default for Gh {
    fn default() -> Self {
        Self {
            program: "gh".into(),
            env: login::Env::default(),
            timeout: Duration::from_secs(30),
        }
    }
}

impl Gh {
    /// gh as a terminal would start it, including from a Finder or Dock launch.
    pub fn resolved() -> Self {
        Self {
            env: login::environment(),
            ..Self::default()
        }
    }

    /// The newest `size` (at most 100) matches for `SECTIONS[section]`.
    pub fn section(&self, section: usize, size: u32, direct_only: bool) -> SectionFetch {
        let alias = SECTIONS[section].alias;
        let routing = Routing::of(section, direct_only);
        let query = section_query(alias, &search(section, direct_only), size, routing);
        match self.graphql(&query) {
            Ok(output) => parse_section(alias, routing, &output),
            Err(err) => SectionFetch {
                identity: None,
                page: Err(err),
                warnings: Vec::new(),
            },
        }
    }

    /// Check states for up to 100 PR node ids.
    pub fn checks(&self, ids: &[String]) -> ChecksFetch {
        match self.graphql(&checks_query(ids)) {
            Ok(output) => parse_checks(ids, &output),
            Err(err) => ChecksFetch {
                identity: None,
                results: ids
                    .iter()
                    .map(|id| (id.clone(), Err(err.clone())))
                    .collect(),
            },
        }
    }

    pub fn membership(&self) -> MembershipFetch {
        let unknown = MembershipFetch {
            identity: None,
            membership: Membership::Unknown,
        };
        let query = format!("query={MEMBERSHIP_QUERY}");
        match self.run(&["api", "--include", "graphql", "-f", &query]) {
            Ok(output) => parse_membership(&output).unwrap_or(unknown),
            Err(_) => unknown,
        }
    }

    fn graphql(&self, query: &str) -> Result<Output, Error> {
        self.run(&["api", "graphql", "-f", &format!("query={query}")])
    }

    fn run(&self, args: &[&str]) -> Result<Output, Error> {
        let mut command = Command::new(&self.program);
        command
            .args(args)
            .envs(self.env.iter().map(|(k, v)| (k, v)));
        capture(&mut command, self.timeout)
    }
}

/// The deadline covers reading output too: a descendant that inherits a pipe
/// can hold it open after the child exits. The child runs in its own process
/// group so a timeout stops every process it started.
fn capture(command: &mut Command, timeout: Duration) -> Result<Output, Error> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => Error::NotInstalled,
            _ => Error::Spawn(e.to_string()),
        })?;
    let (tx, rx) = mpsc::channel();
    drain(child.stdout.take(), Pipe::Stdout, tx.clone());
    drain(child.stderr.take(), Pipe::Stderr, tx);

    let deadline = Instant::now() + timeout;
    let timed_out = |child: &mut Child| {
        stop_group(child);
        Err(Error::Timeout(timeout))
    };
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => return timed_out(&mut child),
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(e) => return Err(Error::Spawn(e.to_string())),
        }
    };
    let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
    for _ in 0..2 {
        match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok((Pipe::Stdout, bytes)) => stdout = bytes,
            Ok((Pipe::Stderr, bytes)) => stderr = bytes,
            Err(_) => return timed_out(&mut child),
        }
    }
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

fn stop_group(child: &mut Child) {
    if let Ok(pid) = i32::try_from(child.id()) {
        // SAFETY: signals only the group spawned above, whose id is gh's pid.
        unsafe { libc::killpg(pid, libc::SIGKILL) };
    }
    let _ = child.kill();
    let _ = child.wait();
}

struct Output {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

enum Pipe {
    Stdout,
    Stderr,
}

fn drain(pipe: Option<impl Read + Send + 'static>, which: Pipe, tx: mpsc::Sender<(Pipe, Vec<u8>)>) {
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(mut pipe) = pipe {
            let _ = pipe.read_to_end(&mut buf);
        }
        let _ = tx.send((which, buf));
    });
}

/// A response's data and errors, or why there is no usable response. gh exits
/// non-zero on any GraphQL error but still prints the partial data, so stdout
/// is read either way.
fn decode_response(output: &Output) -> Result<Answered, Error> {
    let failed = || Error::from_failure(output.status, &output.stderr);
    let response: Response = match serde_json::from_slice(&output.stdout) {
        Ok(response) => response,
        Err(_) if !output.status.success() => return Err(failed()),
        Err(err) => return Err(Error::Parse(err.to_string())),
    };
    let errors = response.errors;
    let first_error = || {
        errors
            .first()
            .map(GraphqlError::to_error)
            .unwrap_or_else(failed)
    };
    let Some(mut data) = response.data else {
        return Err(first_error());
    };
    let viewer = data
        .remove("viewer")
        .and_then(|v| serde_json::from_value::<Viewer>(v).ok());
    let Some(viewer) = viewer else {
        return Err(first_error());
    };
    let identity = Identity {
        login: viewer.login,
        host: host(&viewer.url).to_owned(),
    };
    Ok(Answered {
        identity,
        data,
        errors,
    })
}

/// A response that names its viewer.
struct Answered {
    identity: Identity,
    data: serde_json::Map<String, Value>,
    errors: Vec<GraphqlError>,
}

/// Each item is decoded separately so one bad value costs only itself.
/// Errors elsewhere in the response belong to this section too: it is the
/// only thing the request asked for besides the viewer.
fn parse_section(alias: &str, routing: Routing, output: &Output) -> SectionFetch {
    let Answered {
        identity,
        mut data,
        errors,
    } = match decode_response(output) {
        Ok(answered) => answered,
        Err(err) => {
            return SectionFetch {
                identity: None,
                page: Err(err),
                warnings: Vec::new(),
            };
        }
    };
    let mut warnings: Vec<Error> = Vec::new();
    for err in &errors {
        let err = err.to_error();
        if !warnings.contains(&err) {
            warnings.push(err);
        }
    }
    let value = data.remove(alias).unwrap_or(Value::Null);
    let page = match decode_section(value, &identity.login, routing) {
        Ok(decoded) => {
            if decoded.withheld > 0 && warnings.is_empty() {
                warnings.push(Error::Withheld(decoded.withheld));
            }
            if decoded.unreadable > 0 {
                warnings.push(Error::Unreadable(decoded.unreadable));
            }
            let mut items = decoded.items;
            rank(&mut items);
            Ok(Page {
                items,
                total: decoded.total,
                truncated: decoded.truncated,
                returned: decoded.returned,
            })
        }
        Err(problem) if warnings.is_empty() => Err(problem),
        Err(_) => Err(warnings.remove(0)),
    };
    SectionFetch {
        identity: Some(identity),
        page,
        warnings,
    }
}

/// `gh api --include` prints the status line and headers before the body.
fn parse_membership(output: &Output) -> Option<MembershipFetch> {
    let text = std::str::from_utf8(&output.stdout).ok()?;
    let (head, body) = text
        .split_once("\r\n\r\n")
        .filter(|(head, _)| !head.contains("\n\n"))
        .or_else(|| text.split_once("\n\n"))?;
    let scopes: Option<Vec<&str>> = head.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim()
            .eq_ignore_ascii_case("x-oauth-scopes")
            .then(|| value.split(',').map(str::trim).collect())
    });
    let Answered {
        identity,
        mut data,
        errors,
    } = decode_response(&Output {
        status: output.status,
        stdout: body.as_bytes().to_vec(),
        stderr: output.stderr.clone(),
    })
    .ok()?;
    let count = data
        .remove("memberships")
        .and_then(|v| v.pointer("/organizations/totalCount")?.as_u64());
    let sees_private = scopes.is_some_and(|s| s.iter().any(|s| ORG_SCOPES.contains(s)));
    let membership = match count {
        Some(n) if n > 0 => Membership::Member,
        Some(0) if errors.is_empty() && sees_private => Membership::None,
        _ => Membership::Unknown,
    };
    Some(MembershipFetch {
        identity: Some(identity),
        membership,
    })
}

/// Every requested id gets an answer: its state, the error GitHub gave for
/// it, or why it is missing.
fn parse_checks(ids: &[String], output: &Output) -> ChecksFetch {
    let all = |err: Error| {
        ids.iter()
            .map(|id| (id.clone(), Err(err.clone())))
            .collect()
    };
    let Answered {
        identity,
        mut data,
        errors,
    } = match decode_response(output) {
        Ok(answered) => answered,
        Err(err) => {
            return ChecksFetch {
                identity: None,
                results: all(err),
            };
        }
    };
    let nodes = match data.remove("nodes") {
        Some(Value::Array(nodes)) => nodes,
        _ => {
            let err = errors
                .first()
                .map(GraphqlError::to_error)
                .unwrap_or_else(|| Error::Parse("no nodes in the response".into()));
            return ChecksFetch {
                identity: Some(identity),
                results: all(err),
            };
        }
    };
    let unscoped = errors
        .iter()
        .find(|e| e.path.first().and_then(Value::as_str) != Some("nodes"));
    let results = ids
        .iter()
        .enumerate()
        .map(|(i, id)| {
            let own = errors.iter().find(|e| {
                e.path.first().and_then(Value::as_str) == Some("nodes")
                    && e.path.get(1).and_then(Value::as_u64) == Some(i as u64)
            });
            let result = match (nodes.get(i), own) {
                (_, Some(err)) => Err(err.to_error()),
                (None | Some(Value::Null), None) => {
                    Err(unscoped.map_or(Error::Withheld(1), GraphqlError::to_error))
                }
                (Some(node), None) => serde_json::from_value::<ChecksNode>(node.clone())
                    .ok()
                    .filter(|n| &n.id == id)
                    .map(ChecksNode::into_state)
                    .ok_or(Error::Unreadable(1)),
            };
            (id.clone(), result)
        })
        .collect();
    ChecksFetch {
        identity: Some(identity),
        results,
    }
}

struct Decoded {
    items: Vec<Item>,
    total: u64,
    truncated: bool,
    returned: usize,
    withheld: usize,
    unreadable: usize,
}

fn decode_section(value: Value, viewer_login: &str, routing: Routing) -> Result<Decoded, Error> {
    if value.is_null() {
        return Err(Error::Gh(
            "GitHub returned no results for this section".into(),
        ));
    }
    let connection: Connection =
        serde_json::from_value(value).map_err(|e| Error::Parse(e.to_string()))?;
    let mut decoded = Decoded {
        items: Vec::new(),
        total: connection.issue_count,
        truncated: connection.page_info.has_next_page,
        returned: connection.nodes.len(),
        withheld: 0,
        unreadable: 0,
    };
    for node in connection.nodes {
        if node.is_null() {
            decoded.withheld += 1;
            continue;
        }
        match serde_json::from_value::<Node>(node) {
            Ok(node) => decoded.items.extend(node.into_item(viewer_login, routing)),
            Err(_) => decoded.unreadable += 1,
        }
    }
    Ok(decoded)
}

/// `https://ghe.example.com/login` -> `ghe.example.com`.
fn host(profile_url: &str) -> &str {
    let rest = profile_url
        .split_once("://")
        .map_or(profile_url, |(_, rest)| rest);
    rest.split_once('/').map_or(rest, |(host, _)| host)
}

/// Percent-encodes everything but RFC 3986 unreserved characters.
fn encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[derive(Deserialize)]
struct Response {
    data: Option<serde_json::Map<String, Value>>,
    #[serde(default)]
    errors: Vec<GraphqlError>,
}

#[derive(Deserialize)]
struct Viewer {
    login: String,
    url: String,
}

#[derive(Deserialize)]
struct GraphqlError {
    #[serde(rename = "type")]
    kind: Option<String>,
    message: String,
    #[serde(default)]
    path: Vec<Value>,
}

impl GraphqlError {
    fn to_error(&self) -> Error {
        Error::classify(self.kind.as_deref(), &self.message)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Connection {
    issue_count: u64,
    page_info: PageInfo,
    /// `null` entries are items the token may not see, e.g. behind SSO.
    nodes: Vec<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PageInfo {
    has_next_page: bool,
}

#[derive(Deserialize)]
#[serde(tag = "__typename")]
enum Node {
    PullRequest(PullRequestNode),
    Issue(IssueNode),
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PullRequestNode {
    id: String,
    number: u64,
    title: String,
    url: String,
    updated_at: String,
    is_draft: bool,
    review_decision: Option<String>,
    head_ref_oid: String,
    author: Option<Login>,
    repository: Repository,
    latest_opinionated_reviews: Option<Reviews>,
    review_requests: Option<ReviewRequests>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IssueNode {
    id: String,
    number: u64,
    title: String,
    url: String,
    updated_at: String,
    author: Option<Login>,
    repository: Repository,
}

#[derive(Deserialize)]
struct Login {
    login: String,
}

#[derive(Deserialize)]
struct Nodes<T> {
    nodes: Vec<Option<T>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Reviews {
    page_info: PageInfo,
    nodes: Vec<Option<ReviewNode>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReviewRequests {
    page_info: PageInfo,
    nodes: Vec<Option<ReviewRequestNode>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReviewRequestNode {
    requested_reviewer: Option<RequestedReviewer>,
}

#[derive(Deserialize)]
#[serde(tag = "__typename")]
enum RequestedReviewer {
    User {
        login: String,
    },
    Bot {
        login: String,
    },
    Mannequin {
        login: String,
    },
    Team {
        name: String,
    },
    #[serde(other)]
    Other,
}

/// A direct request settles it even on a partial list; anything else needs
/// the whole list, since a missing entry could be the viewer.
fn review_route(requests: Option<ReviewRequests>, viewer_login: &str) -> ReviewRoute {
    let Some(requests) = requests else {
        return ReviewRoute::Unknown;
    };
    let mut complete = !requests.page_info.has_next_page;
    let mut teams = Vec::new();
    for reviewer in requests
        .nodes
        .into_iter()
        .map(|n| n.and_then(|n| n.requested_reviewer))
    {
        match reviewer {
            Some(
                RequestedReviewer::User { login }
                | RequestedReviewer::Bot { login }
                | RequestedReviewer::Mannequin { login },
            ) if login == viewer_login => return ReviewRoute::Direct,
            Some(
                RequestedReviewer::User { .. }
                | RequestedReviewer::Bot { .. }
                | RequestedReviewer::Mannequin { .. },
            ) => {}
            Some(RequestedReviewer::Team { name }) => teams.push(name),
            Some(RequestedReviewer::Other) | None => complete = false,
        }
    }
    match teams.len() {
        _ if !complete => ReviewRoute::Unknown,
        0 => ReviewRoute::Unknown,
        1 => ReviewRoute::Team(teams.remove(0)),
        _ => ReviewRoute::SomeTeam,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChecksNode {
    id: String,
    head_ref_oid: String,
    commits: Nodes<CommitNode>,
    potential_merge_commit: Option<Commit>,
    base_ref: Option<BaseRef>,
}

impl ChecksNode {
    /// The rollup of the commit GitHub requires to pass (the test merge
    /// commit when it has a status, else the head), except that a required
    /// check absent from its complete list keeps it pending; a failure wins.
    fn into_state(self) -> CheckState {
        let head = self
            .commits
            .nodes
            .into_iter()
            .flatten()
            .next()
            .and_then(|c| c.commit.status_check_rollup);
        let rollup = self
            .potential_merge_commit
            .and_then(|c| c.status_check_rollup)
            .or(head);
        let reported = rollup.as_ref().and_then(|r| checks(&r.state));
        let ran = match &rollup {
            None => Some(Vec::new()),
            Some(r) => r.contexts.as_ref().and_then(Contexts::complete),
        };
        let required = self.base_ref.map(BaseRef::required).unwrap_or_default();
        let awaited = ran.is_some_and(|ran| required.iter().any(|c| !ran.contains(&c.as_str())));
        let checks = match reported {
            Some(Checks::Failing) => reported,
            _ if awaited => Some(Checks::Pending),
            _ => reported,
        };
        CheckState {
            head: self.head_ref_oid,
            checks,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Rollup {
    state: String,
    contexts: Option<Contexts>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Contexts {
    total_count: usize,
    nodes: Vec<Option<Context>>,
}

impl Contexts {
    /// Every reported check's name, or `None` when some went unread.
    fn complete(&self) -> Option<Vec<&str>> {
        let names: Vec<&str> = self
            .nodes
            .iter()
            .flatten()
            .filter_map(|c| c.name.as_deref().or(c.context.as_deref()))
            .collect();
        (names.len() == self.total_count).then_some(names)
    }
}

#[derive(Deserialize)]
struct Context {
    /// A check run's.
    name: Option<String>,
    /// A commit status's.
    context: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BaseRef {
    branch_protection_rule: Option<ProtectionRule>,
    rules: Option<Nodes<Rule>>,
}

impl BaseRef {
    /// Required check names from branch protection and rulesets alike.
    fn required(self) -> Vec<String> {
        let classic = self
            .branch_protection_rule
            .and_then(|r| r.required_status_check_contexts)
            .unwrap_or_default();
        let rulesets = self
            .rules
            .into_iter()
            .flat_map(|r| r.nodes)
            .flatten()
            .filter_map(|r| r.parameters?.required_status_checks)
            .flatten()
            .map(|c| c.context);
        classic.into_iter().chain(rulesets).collect()
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProtectionRule {
    required_status_check_contexts: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct Rule {
    parameters: Option<RuleParameters>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuleParameters {
    required_status_checks: Option<Vec<RequiredCheck>>,
}

#[derive(Deserialize)]
struct RequiredCheck {
    context: String,
}

#[derive(Deserialize)]
struct CommitNode {
    commit: Commit,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Commit {
    status_check_rollup: Option<Rollup>,
}

#[derive(Deserialize)]
struct ReviewNode {
    state: String,
}

/// Deleted accounts come back as a null author.
const GHOST: &str = "ghost";

impl Node {
    fn into_item(self, viewer_login: &str, routing: Routing) -> Option<Item> {
        match self {
            Node::PullRequest(pr) => {
                // A null opinion is one GitHub withheld, so as unknown as a further page.
                let (latest, complete) = match pr.latest_opinionated_reviews {
                    Some(r) => {
                        let complete =
                            !r.page_info.has_next_page && r.nodes.iter().all(Option::is_some);
                        (
                            r.nodes.into_iter().flatten().map(|n| n.state).collect(),
                            complete,
                        )
                    }
                    None => (Vec::new(), false),
                };
                let review_route = match routing {
                    Routing::NotAsked => None,
                    Routing::AllDirect => Some(ReviewRoute::Direct),
                    Routing::FromRequests => Some(review_route(pr.review_requests, viewer_login)),
                };
                Some(Item {
                    id: pr.id,
                    number: pr.number,
                    title: pr.title,
                    repository: pr.repository,
                    is_pull_request: true,
                    is_draft: pr.is_draft,
                    head: Some(pr.head_ref_oid),
                    review: review(pr.review_decision.as_deref(), &latest, complete),
                    review_route,
                    url: pr.url,
                    updated_at: pr.updated_at,
                    author: pr.author.map_or_else(|| GHOST.to_owned(), |a| a.login),
                })
            }
            Node::Issue(issue) => Some(Item {
                id: issue.id,
                number: issue.number,
                title: issue.title,
                repository: issue.repository,
                is_pull_request: false,
                is_draft: false,
                head: None,
                review: None,
                review_route: None,
                url: issue.url,
                updated_at: issue.updated_at,
                author: issue.author.map_or_else(|| GHOST.to_owned(), |a| a.login),
            }),
            Node::Other => None,
        }
    }
}

/// GitHub's StatusState values.
fn checks(state: &str) -> Option<Checks> {
    match state {
        "SUCCESS" => Some(Checks::Passing),
        "FAILURE" | "ERROR" => Some(Checks::Failing),
        "PENDING" | "EXPECTED" => Some(Checks::Pending),
        _ => None,
    }
}

/// The branch rule's decision when there is one, else the reviewers' latest
/// opinions. A change request anywhere is outstanding; approval is claimed
/// only when every reviewer's opinion was fetched (`complete`).
fn review(decision: Option<&str>, latest: &[String], complete: bool) -> Option<Review> {
    match decision {
        Some("APPROVED") => Some(Review::Approved),
        Some("CHANGES_REQUESTED") => Some(Review::ChangesRequested),
        Some("REVIEW_REQUIRED") => Some(Review::Required),
        _ if latest.iter().any(|s| s == "CHANGES_REQUESTED") => Some(Review::ChangesRequested),
        _ if complete && latest.iter().any(|s| s == "APPROVED") => Some(Review::Approved),
        _ => None,
    }
}

/// Needs-attention items first, then approved PRs, then drafts; most recent
/// activity first within each.
pub fn rank(items: &mut [Item]) {
    // RFC 3339 UTC timestamps sort lexically.
    items.sort_by(|a, b| {
        a.tier()
            .cmp(&b.tier())
            .then_with(|| b.updated_at.cmp(&a.updated_at))
    });
}

#[cfg(test)]
mod tests;
