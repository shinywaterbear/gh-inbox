use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use serde_json::json;

use super::*;

const RECORDED: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/mocks/graphql.json");

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("gh-inbox-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A fake gh running `body` as a bash script.
fn fake_gh(name: &str, body: &str) -> Gh {
    let path = scratch(name).join("gh");
    std::fs::write(&path, format!("#!/usr/bin/env bash\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    Gh {
        program: path.into(),
        timeout: Duration::from_secs(10),
        ..Gh::default()
    }
}

/// A fake gh that prints `json` and exits with `code`, as gh does for GraphQL errors.
fn responding(name: &str, json: Value, code: i32) -> Gh {
    let file = scratch(name).join("response.json");
    std::fs::write(&file, json.to_string()).unwrap();
    fake_gh(name, &format!("cat '{}'\nexit {code}", file.display()))
}

const REVIEW: usize = 0;
const AUTHORED: usize = 1;

/// A section that loaded, and its warnings.
fn page(fetch: SectionFetch) -> (Page, Vec<Error>) {
    assert!(fetch.identity.is_some(), "no identity");
    match fetch.page {
        Ok(page) => (page, fetch.warnings),
        Err(err) => panic!("section failed: {err}"),
    }
}

fn items(fetch: SectionFetch) -> Vec<Item> {
    page(fetch).0.items
}

/// No usable response at all.
fn unavailable(fetch: SectionFetch) -> Error {
    assert!(fetch.identity.is_none(), "expected no identity");
    fetch.page.expect_err("expected a failure")
}

fn pr(number: u64, updated_at: &str, draft: bool, decision: Option<&str>) -> Value {
    json!({
        "__typename": "PullRequest", "number": number, "title": "t",
        "url": format!("https://github.com/o/r/pull/{number}"), "updatedAt": updated_at,
        "id": format!("PR_{number}"), "headRefOid": format!("sha{number}"),
        "isDraft": draft, "reviewDecision": decision, "author": {"login": "a"},
        "repository": {"name": "r", "nameWithOwner": "o/r"},
        "latestOpinionatedReviews": {"pageInfo": {"hasNextPage": false}, "nodes": []},
    })
}

fn conn(nodes: Value) -> Value {
    let count = nodes.as_array().map_or(0, Vec::len);
    json!({"issueCount": count, "pageInfo": {"hasNextPage": false}, "nodes": nodes})
}

/// `review` and `authored` as given; the other two sections empty. Each
/// section's request reads only its own alias.
fn response(review: Value, authored: Value) -> Value {
    json!({"data": {
        "viewer": {"login": "me", "url": "https://github.com/me"},
        "review": review, "authored": authored,
        "assigned": conn(json!([])), "personal": conn(json!([])),
    }})
}

/// Runs a fake gh that records its arguments, returning the query sent.
fn sent_query(name: &str, call: impl FnOnce(&Gh)) -> String {
    let args = scratch(name).join("args");
    let gh = fake_gh(
        name,
        &format!(
            "printf '%s\\n' \"$@\" > '{}'\ncat '{RECORDED}'",
            args.display()
        ),
    );
    call(&gh);
    let args = std::fs::read_to_string(args).unwrap();
    let mut lines = args.lines();
    assert_eq!(
        (lines.next(), lines.next(), lines.next()),
        (Some("api"), Some("graphql"), Some("-f"))
    );
    let sent = args.splitn(4, '\n').nth(3).unwrap();
    assert!(sent.starts_with("query=query {"));
    assert!(
        sent.contains("viewer { login url }"),
        "every request names its account"
    );
    sent.to_owned()
}

#[test]
fn each_section_sends_one_search_of_the_size_asked() {
    for (index, spec) in SECTIONS.iter().enumerate() {
        let sent = sent_query(spec.alias, |gh| {
            gh.section(index, 50, false);
        });
        let search = search(index, false);
        assert!(sent.contains(&format!(
            "{}: search(query: \"{search}\", type: ISSUE, first: 50)",
            spec.alias
        )));
        assert_eq!(sent.matches("search(").count(), 1);
        assert!(search.ends_with(" sort:updated-desc"), "{}", spec.alias);
        assert!(sent.contains("fragment items on SearchResultItemConnection"));
        assert_eq!(
            sent.contains("reviewRequests"),
            index == REVIEW,
            "only the review section reads requests: {}",
            spec.alias
        );
        assert!(
            !sent.contains("statusCheckRollup"),
            "checks load separately"
        );
    }
}

#[test]
fn check_lookups_send_the_ids() {
    let ids = ["PR_a".to_owned(), "PR_b".to_owned()];
    let sent = sent_query("check-args", |gh| {
        gh.checks(&ids);
    });
    assert!(sent.contains(r#"nodes(ids: ["PR_a","PR_b"])"#));
    assert!(sent.contains("fragment checks on PullRequest"));
}

#[test]
fn parses_recorded_response_per_section() {
    let gh = fake_gh("recorded", &format!("cat '{RECORDED}'"));
    let fetch = gh.section(AUTHORED, 25, false);
    assert_eq!(
        fetch.identity,
        Some(Identity {
            login: "example-user".into(),
            host: "github.com".into()
        })
    );
    let (authored, warnings) = page(fetch);
    assert!(warnings.is_empty() && !authored.truncated);
    assert_eq!(authored.items.len(), 3);
    assert!(
        authored.items[1..].iter().all(|i| i.is_draft),
        "drafts last"
    );
    assert!(authored.items.iter().all(|i| i.head.is_some()));
    for index in 0..SECTIONS.len() {
        let (section, warnings) = page(gh.section(index, 25, false));
        assert!(!section.truncated && warnings.is_empty(), "{index}");
    }
}

#[test]
fn missing_binary_is_not_installed() {
    let gh = Gh {
        program: "/nonexistent/gh".into(),
        ..Gh::default()
    };
    assert_eq!(
        unavailable(gh.section(REVIEW, 25, false)),
        Error::NotInstalled
    );
}

#[test]
fn logged_out_is_one_error_not_one_per_section() {
    let gh = fake_gh(
        "logged-out",
        "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4",
    );
    assert_eq!(
        unavailable(gh.section(REVIEW, 25, false)),
        Error::NotLoggedIn
    );
}

#[test]
fn rejected_token_is_bad_credentials() {
    // gh prints the 401 body on stdout and its summary on stderr.
    let gh = fake_gh(
        "bad-token",
        "echo '{\"message\":\"Bad credentials\",\"status\":\"401\"}'\n\
         echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1",
    );
    assert!(matches!(
        unavailable(gh.section(REVIEW, 25, false)),
        Error::BadCredentials(_)
    ));
}

#[test]
fn network_failure_is_network() {
    let gh = fake_gh(
        "network",
        "echo 'dial tcp: lookup api.github.com: no such host' >&2; exit 1",
    );
    assert!(matches!(
        unavailable(gh.section(REVIEW, 25, false)),
        Error::Network(_)
    ));
}

#[test]
fn hung_gh_times_out() {
    let mut gh = fake_gh("hung", "sleep 5");
    gh.timeout = Duration::from_millis(200);
    let started = Instant::now();
    assert!(matches!(
        unavailable(gh.section(REVIEW, 25, false)),
        Error::Timeout(_)
    ));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn a_descendant_holding_the_pipe_cannot_outlive_the_timeout() {
    // gh exits at once, but a background child keeps stdout open.
    let mut gh = fake_gh("held-pipe", "sleep 5 &\nexit 0");
    gh.timeout = Duration::from_millis(300);
    let started = Instant::now();
    assert!(matches!(
        unavailable(gh.section(REVIEW, 25, false)),
        Error::Timeout(_)
    ));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[test]
fn garbage_output_is_a_parse_error() {
    let gh = fake_gh("garbage", "echo 'not json'");
    assert!(matches!(
        unavailable(gh.section(REVIEW, 25, false)),
        Error::Parse(_)
    ));
}

#[test]
fn whole_query_rate_limit_is_unavailable() {
    let json = json!({"errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]});
    let gh = responding("rate-limited", json, 1);
    assert!(matches!(
        unavailable(gh.section(REVIEW, 25, false)),
        Error::RateLimited(_)
    ));
}

#[test]
fn a_failed_search_still_names_the_account() {
    let mut json = response(Value::Null, conn(json!([])));
    json["errors"] =
        json!([{"type": "FORBIDDEN", "path": ["review"], "message": "Resource not accessible"}]);
    let fetch = responding("one-section", json, 1).section(REVIEW, 25, false);
    assert!(fetch.identity.is_some());
    assert!(matches!(fetch.page, Err(Error::Forbidden(_))));
}

#[test]
fn a_malformed_section_is_a_parse_error() {
    let json = response(json!({"nodes": "not a list"}), conn(json!([])));
    let fetch = responding("malformed-section", json, 0).section(REVIEW, 25, false);
    assert!(matches!(fetch.page, Err(Error::Parse(_))));
}

#[test]
fn a_malformed_item_costs_only_itself_and_is_reported() {
    let mut broken = pr(2, "2026-11-01T00:00:00Z", false, None);
    broken["title"] = Value::Null;
    let json = response(
        conn(json!([broken, pr(3, "2026-11-01T00:00:00Z", false, None)])),
        conn(json!([])),
    );
    let (review, warnings) = page(responding("malformed-item", json, 0).section(REVIEW, 25, false));
    assert_eq!(review.items.len(), 1);
    assert_eq!(warnings, [Error::Unreadable(1)]);
}

#[test]
fn sso_withheld_items_keep_the_rest_and_say_so() {
    let mut json = response(
        conn(json!([null, pr(2, "2026-11-01T00:00:00Z", false, None)])),
        conn(json!([])),
    );
    json["errors"] = json!([{
        "type": "FORBIDDEN", "path": ["review", "nodes", 0],
        "message": "Resource protected by organization SAML enforcement.",
    }]);
    let (review, warnings) = page(responding("sso", json, 1).section(REVIEW, 25, false));
    assert_eq!(review.items.len(), 1);
    assert!(matches!(warnings.as_slice(), [Error::Forbidden(_)]));
}

#[test]
fn unexplained_missing_items_still_warn() {
    let json = response(conn(json!([null])), conn(json!([])));
    let (_, warnings) = page(responding("silent-null", json, 0).section(REVIEW, 25, false));
    assert_eq!(warnings, [Error::Withheld(1)]);
}

#[test]
fn an_error_inside_a_present_item_is_not_lost() {
    let mut json = response(
        conn(json!([pr(4, "2026-11-01T00:00:00Z", false, None)])),
        conn(json!([])),
    );
    json["errors"] = json!([{
        "type": "FORBIDDEN", "path": ["review", "nodes", 0, "commits"],
        "message": "Resource not accessible by integration",
    }]);
    let (review, warnings) = page(responding("nested", json, 1).section(REVIEW, 25, false));
    assert_eq!(review.items.len(), 1);
    assert!(matches!(warnings.as_slice(), [Error::Forbidden(_)]));
}

#[test]
fn errors_without_a_path_warn_the_section_that_asked() {
    let mut json = response(conn(json!([])), conn(json!([])));
    json["errors"] = json!([{"type": "INTERNAL", "message": "Something went wrong"}]);
    let (_, warnings) = page(responding("unscoped", json, 1).section(REVIEW, 25, false));
    assert!(matches!(warnings.as_slice(), [Error::Gh(m)] if m == "Something went wrong"));
}

#[test]
fn truncated_sections_say_so_and_link_the_full_search() {
    let mut json = response(
        conn(json!([pr(1, "2026-11-01T00:00:00Z", false, None)])),
        conn(json!([])),
    );
    json["data"]["review"]["issueCount"] = json!(342);
    json["data"]["review"]["pageInfo"]["hasNextPage"] = json!(true);
    let (review, _) = page(responding("truncated", json, 0).section(REVIEW, 25, false));
    assert!(review.truncated);
    assert_eq!(review.total, 342);
    assert_eq!(
        search_url(REVIEW, "github.com", false),
        "https://github.com/search?type=issues&q=is%3Aopen%20is%3Apr%20archived%3Afalse%20review-requested%3A%40me%20sort%3Aupdated-desc"
    );
    assert_eq!(
        search_url(REVIEW, "github.com", true),
        "https://github.com/search?type=issues&q=is%3Aopen%20is%3Apr%20archived%3Afalse%20user-review-requested%3A%40me%20sort%3Aupdated-desc"
    );
}

#[test]
fn search_links_follow_the_viewers_host() {
    let mut json = response(conn(json!([])), conn(json!([])));
    json["data"]["viewer"]["url"] = json!("https://ghe.example.com/me");
    let host = responding("ghe", json, 0)
        .section(REVIEW, 25, false)
        .identity
        .unwrap()
        .host;
    assert_eq!(host, "ghe.example.com");
    assert!(search_url(REVIEW, &host, false).starts_with("https://ghe.example.com/search?"));
}

#[test]
fn approved_and_draft_prs_sink_in_that_order() {
    let json = response(
        conn(json!([
            pr(1, "2026-11-04T00:00:00Z", true, None),
            pr(2, "2026-11-03T00:00:00Z", false, Some("APPROVED")),
            pr(3, "2026-10-01T00:00:00Z", false, Some("REVIEW_REQUIRED")),
            pr(4, "2026-11-02T00:00:00Z", false, None),
        ])),
        conn(json!([])),
    );
    let numbers: Vec<_> = items(responding("rank", json, 0).section(REVIEW, 25, false))
        .iter()
        .map(|i| i.number)
        .collect();
    assert_eq!(numbers, [4, 3, 2, 1]);
}

#[test]
fn reviews_decide_only_from_complete_opinions() {
    let approved = ["APPROVED".to_owned()];
    assert_eq!(review(None, &approved, true), Some(Review::Approved));
    assert_eq!(
        review(None, &approved, false),
        None,
        "an unseen reviewer may object"
    );
    let mixed = ["APPROVED".to_owned(), "CHANGES_REQUESTED".to_owned()];
    assert_eq!(review(None, &mixed, false), Some(Review::ChangesRequested));
    assert_eq!(
        review(Some("REVIEW_REQUIRED"), &approved, true),
        Some(Review::Required)
    );
    assert_eq!(review(None, &[], true), None);
}

#[test]
fn check_states_map_to_three_colors() {
    assert_eq!(checks("SUCCESS"), Some(Checks::Passing));
    assert_eq!(checks("ERROR"), Some(Checks::Failing));
    assert_eq!(checks("EXPECTED"), Some(Checks::Pending));
}

#[test]
fn deleted_authors_show_as_ghost() {
    let mut item = pr(6, "2026-11-01T00:00:00Z", false, None);
    item["author"] = Value::Null;
    let json = response(conn(json!([item])), conn(json!([])));
    let authors = items(responding("ghost", json, 0).section(REVIEW, 25, false));
    assert_eq!(authors[0].author, GHOST);
}

#[test]
fn a_withheld_reviewer_opinion_blocks_inferred_approval() {
    let mut item = pr(7, "2026-11-01T00:00:00Z", false, None);
    item["latestOpinionatedReviews"]["nodes"] = json!([{"state": "APPROVED"}, null]);
    let json = response(conn(json!([item])), conn(json!([])));
    let reviewed = items(responding("null-review", json, 0).section(REVIEW, 25, false));
    assert_eq!(reviewed[0].review, None);
}

/// The review section's route for a PR whose request list is `nodes`.
fn route(name: &str, nodes: Value, has_next_page: bool) -> Option<ReviewRoute> {
    let mut item = pr(8, "2026-11-01T00:00:00Z", false, None);
    item["reviewRequests"] = json!({"pageInfo": {"hasNextPage": has_next_page}, "nodes": nodes});
    let json = response(conn(json!([item])), conn(json!([])));
    items(responding(name, json, 0).section(REVIEW, 25, false))[0]
        .review_route
        .clone()
}

fn user(login: &str) -> Value {
    json!({"requestedReviewer": {"__typename": "User", "login": login}})
}

fn team(name: &str) -> Value {
    json!({"requestedReviewer": {"__typename": "Team", "name": name}})
}

#[test]
fn a_direct_request_wins_over_teams_even_on_a_partial_list() {
    let nodes = json!([team("platform"), user("other"), user("me")]);
    assert_eq!(
        route("mixed", nodes.clone(), false),
        Some(ReviewRoute::Direct)
    );
    assert_eq!(route("mixed-cut", nodes, true), Some(ReviewRoute::Direct));
    let behind_null = json!([null, {"requestedReviewer": null}, user("me")]);
    assert_eq!(
        route("null-then-me", behind_null, false),
        Some(ReviewRoute::Direct)
    );
}

#[test]
fn only_a_complete_list_with_one_team_names_it() {
    assert_eq!(
        route("one-team", json!([user("other"), team("platform")]), false),
        Some(ReviewRoute::Team("platform".into()))
    );
    assert_eq!(
        route(
            "two-teams",
            json!([team("platform"), team("security")]),
            false
        ),
        Some(ReviewRoute::SomeTeam),
        "not the first one listed"
    );
}

#[test]
fn a_cut_off_or_withheld_request_list_is_unknown() {
    assert_eq!(
        route("cut-off", json!([team("platform")]), true),
        Some(ReviewRoute::Unknown),
        "the viewer may be past the page"
    );
    assert_eq!(
        route("null-node", json!([team("platform"), null]), false),
        Some(ReviewRoute::Unknown)
    );
    assert_eq!(
        route(
            "null-reviewer",
            json!([team("platform"), {"requestedReviewer": null}]),
            false
        ),
        Some(ReviewRoute::Unknown),
        "a hidden team may be the viewer's"
    );
    assert_eq!(
        route(
            "unsupported",
            json!([{"requestedReviewer": {"__typename": "Robot"}}]),
            false
        ),
        Some(ReviewRoute::Unknown)
    );
    assert_eq!(route("empty", json!([]), false), Some(ReviewRoute::Unknown));
    let item = pr(9, "2026-11-01T00:00:00Z", false, None);
    let json = response(conn(json!([item])), conn(json!([])));
    let missing = items(responding("no-requests", json, 0).section(REVIEW, 25, false));
    assert_eq!(missing[0].review_route, Some(ReviewRoute::Unknown));
}

#[test]
fn the_direct_only_search_needs_no_request_list() {
    let item = pr(10, "2026-11-01T00:00:00Z", false, None);
    let json = response(conn(json!([item])), conn(json!([])));
    let direct = items(responding("direct-search-route", json, 0).section(REVIEW, 25, true));
    assert_eq!(direct[0].review_route, Some(ReviewRoute::Direct));
}

#[test]
fn other_sections_have_no_review_route() {
    let mut item = pr(11, "2026-11-01T00:00:00Z", false, None);
    item["reviewRequests"] =
        json!({"pageInfo": {"hasNextPage": false}, "nodes": [team("platform")]});
    let json = response(conn(json!([])), conn(json!([item])));
    let authored = items(responding("authored-review-field", json, 0).section(AUTHORED, 25, false));
    assert_eq!(authored[0].review_route, None);
}

#[test]
fn repository_owner_typename_tells_personal_from_organization() {
    let mut org_item = pr(11, "2026-11-01T00:00:00Z", false, None);
    org_item["repository"]["owner"] = json!({"__typename": "Organization"});
    let mut personal_item = pr(12, "2026-10-31T00:00:00Z", false, None);
    personal_item["repository"]["owner"] = json!({"__typename": "User"});
    let json = response(conn(json!([org_item, personal_item])), conn(json!([])));
    let found = items(responding("owner-typename", json, 0).section(REVIEW, 25, false));
    let org = found.iter().find(|i| i.number == 11).unwrap();
    let personal = found.iter().find(|i| i.number == 12).unwrap();
    assert_eq!(org.repository.owner_kind(), OwnerKind::Organization);
    assert_eq!(personal.repository.owner_kind(), OwnerKind::Personal);
}

#[test]
fn a_repository_with_no_owner_type_is_unknown_not_personal() {
    let item = pr(13, "2026-11-01T00:00:00Z", false, None);
    let json = response(conn(json!([item])), conn(json!([])));
    let found = items(responding("owner-missing", json, 0).section(REVIEW, 25, false));
    assert_eq!(found[0].repository.owner_kind(), OwnerKind::Unknown);
}

#[test]
fn direct_only_swaps_one_qualifier_and_the_link_follows() {
    let any = search(REVIEW, false);
    let direct = search(REVIEW, true);
    assert_eq!(
        any.replace("review-requested", "user-review-requested"),
        direct
    );
    for (direct_only, expected) in [(false, &any), (true, &direct)] {
        let sent = sent_query(&format!("review-search-{direct_only}"), |gh| {
            gh.section(REVIEW, 25, direct_only);
        });
        assert!(sent.contains(&format!("query: \"{expected}\"")));
        assert_eq!(sent.contains("reviewRequests"), !direct_only);
        assert_eq!(
            search_url(REVIEW, "github.com", direct_only),
            format!(
                "https://github.com/search?type=issues&q={}",
                encode(expected)
            )
        );
    }
    for index in 1..SECTIONS.len() {
        assert_eq!(search(index, true), search(index, false));
    }
}

#[test]
fn page_counts_what_github_returned_not_what_survived() {
    let mut broken = pr(8, "2026-11-01T00:00:00Z", false, None);
    broken["title"] = Value::Null;
    let json = response(
        conn(json!([
            broken,
            null,
            pr(9, "2026-11-01T00:00:00Z", false, None)
        ])),
        conn(json!([])),
    );
    let (review, _) = page(responding("page", json, 0).section(REVIEW, 25, false));
    assert_eq!((review.returned, review.items.len()), (3, 1));
}

#[test]
fn descriptions_end_each_sentence_once() {
    let err = Error::Forbidden("Resource protected by organization SAML enforcement.".into());
    assert_eq!(
        err.describe(),
        "GitHub denied access: Resource protected by organization SAML enforcement. \
         Check `gh auth status`: classic/OAuth tokens need `repo` for private repositories \
         and `read:org` for organization/team access. SSO organizations may require token \
         authorization. If using `GH_TOKEN` or `GITHUB_TOKEN`, check that token instead."
    );
    assert_eq!(Error::Gh("boom".into()).describe(), "gh failed: boom.");
}

#[test]
fn an_ip_allow_list_points_at_the_network() {
    let mut json = response(
        conn(json!([null, pr(2, "2026-11-01T00:00:00Z", false, None)])),
        conn(json!([])),
    );
    json["errors"] = json!([{
        "type": "FORBIDDEN", "path": ["review", "nodes", 0],
        "message": "Although you appear to have the correct authorization credentials, the `o` \
                    organization has an IP allow list enabled, and your IP address is not \
                    permitted to access this resource.",
    }]);
    let (_, warnings) = page(responding("ip-allow-list", json, 1).section(REVIEW, 25, false));
    assert!(matches!(warnings.as_slice(), [Error::IpRestricted(_)]));
    assert!(warnings[0].hint().unwrap().contains("VPN"));
}

#[test]
fn a_bare_502_is_a_server_error() {
    let gh = fake_gh(
        "bare-502",
        "echo '<html>Bad Gateway</html>'\n\
         echo 'gh: HTTP 502: 502 Bad Gateway (https://api.github.com/graphql)' >&2; exit 1",
    );
    assert!(matches!(
        unavailable(gh.section(REVIEW, 25, false)),
        Error::Server(_)
    ));
}

#[test]
fn a_query_timeout_body_is_a_server_error() {
    let json = json!({"data": null, "errors": [{"message":
        "Something went wrong while executing your query. This may be the result of a timeout, \
         or it could be a GitHub bug."}]});
    let err = unavailable(responding("timeout-body", json, 1).section(REVIEW, 25, false));
    assert!(matches!(err, Error::Server(_)));
    assert!(err.hint().is_some());
}

fn check_node(id: &str, head: &str, state: &str) -> Value {
    json!({"__typename": "PullRequest", "id": id, "headRefOid": head,
        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": state}}}]}})
}

fn ids(names: &[&str]) -> Vec<String> {
    names.iter().map(|&n| n.to_owned()).collect()
}

#[test]
fn every_requested_check_gets_an_answer() {
    let mut no_checks = check_node("PR_c", "c1", "SUCCESS");
    no_checks["commits"]["nodes"][0]["commit"]["statusCheckRollup"] = Value::Null;
    let json = json!({
        "data": {
            "viewer": {"login": "me", "url": "https://github.com/me"},
            "nodes": [
                check_node("PR_a", "a1", "FAILURE"),
                null,
                no_checks,
                null,
                check_node("PR_other", "x", "SUCCESS"),
            ],
        },
        "errors": [{"type": "FORBIDDEN", "path": ["nodes", 3], "message": "SAML enforcement"}],
    });
    let fetch =
        responding("checks", json, 1).checks(&ids(&["PR_a", "PR_b", "PR_c", "PR_d", "PR_e"]));
    assert!(fetch.identity.is_some());
    let results: Vec<_> = fetch.results.into_iter().map(|(_, r)| r).collect();
    assert_eq!(
        results[0],
        Ok(CheckState {
            head: "a1".into(),
            checks: Some(Checks::Failing)
        })
    );
    assert_eq!(results[1], Err(Error::Withheld(1)));
    assert_eq!(
        results[2],
        Ok(CheckState {
            head: "c1".into(),
            checks: None
        })
    );
    assert!(matches!(results[3], Err(Error::Forbidden(_))));
    assert_eq!(
        results[4],
        Err(Error::Unreadable(1)),
        "answer for another id"
    );
}

/// A PR whose rollup is `state` over the check runs `ran`, against a base
/// branch whose ruleset requires `required`.
fn gated_node(state: &str, ran: &[&str], total: usize, required: &[&str]) -> Value {
    let runs: Vec<_> = ran
        .iter()
        .map(|n| json!({"__typename": "CheckRun", "name": n}))
        .collect();
    let checks: Vec<_> = required.iter().map(|c| json!({"context": c})).collect();
    let mut node = check_node("PR_a", "a1", state);
    node["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"] =
        json!({"totalCount": total, "nodes": runs});
    node["baseRef"] = json!({
        "branchProtectionRule": null,
        "rules": {"nodes": [
            {"parameters": {"__typename": "RequiredStatusChecksParameters",
                "requiredStatusChecks": checks}},
            {"parameters": null},
        ]},
    });
    node
}

fn gated_state(name: &str, node: Value) -> Option<Checks> {
    let json = json!({"data": {
        "viewer": {"login": "me", "url": "https://github.com/me"},
        "nodes": [node],
    }});
    let fetch = responding(name, json, 0).checks(&ids(&["PR_a"]));
    fetch.results[0].1.as_ref().expect("check state").checks
}

const RAN: &[&str] = &["check", "Game build", "Game browser tests"];

#[test]
fn a_required_check_that_never_reported_is_pending_not_passing() {
    // Seen for real: the ruleset gained a required check after the
    // PR's checks ran, so GitHub's rollup says SUCCESS without it.
    let node = gated_node("SUCCESS", RAN, RAN.len(), &["Gate / Validate"]);
    assert_eq!(gated_state("gated-missing", node), Some(Checks::Pending));
}

#[test]
fn a_required_check_that_reported_leaves_the_rollup_alone() {
    let ran = [RAN, &["Gate / Validate"]].concat();
    let node = gated_node("SUCCESS", &ran, ran.len(), &["Gate / Validate"]);
    assert_eq!(gated_state("gated-reported", node), Some(Checks::Passing));
}

#[test]
fn a_missing_required_check_does_not_hide_a_failure() {
    let node = gated_node("FAILURE", RAN, RAN.len(), &["Gate / Validate"]);
    assert_eq!(gated_state("gated-failing", node), Some(Checks::Failing));
}

#[test]
fn a_required_check_on_a_commit_with_no_checks_is_pending() {
    let mut node = gated_node("SUCCESS", &[], 0, &["Gate / Validate"]);
    node["commits"]["nodes"][0]["commit"]["statusCheckRollup"] = Value::Null;
    assert_eq!(gated_state("gated-no-rollup", node), Some(Checks::Pending));
}

fn with_status(required: &[&str]) -> Value {
    let mut node = gated_node("SUCCESS", RAN, RAN.len() + 1, required);
    node["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["contexts"]["nodes"]
        .as_array_mut()
        .unwrap()
        .push(json!({"__typename": "StatusContext", "context": "ci/legacy"}));
    node
}

#[test]
fn a_required_commit_status_counts_by_its_context() {
    let node = with_status(&["ci/legacy"]);
    assert_eq!(gated_state("gated-status", node), Some(Checks::Passing));
}

#[test]
fn commit_statuses_complete_the_list_that_proves_a_check_missing() {
    let node = with_status(&["ci/legacy", "Gate / Validate"]);
    assert_eq!(
        gated_state("gated-status-missing", node),
        Some(Checks::Pending)
    );
}

#[test]
fn branch_protection_requirements_count_too() {
    let mut node = gated_node("SUCCESS", RAN, RAN.len(), &[]);
    node["baseRef"]["branchProtectionRule"] =
        json!({"requiredStatusCheckContexts": ["Gate / Validate"]});
    assert_eq!(gated_state("gated-classic", node), Some(Checks::Pending));
}

/// `node` with a test merge commit whose rollup is `state` over `ran`.
fn with_merge_commit(mut node: Value, state: &str, ran: &[&str]) -> Value {
    let runs: Vec<_> = ran
        .iter()
        .map(|n| json!({"__typename": "CheckRun", "name": n}))
        .collect();
    node["potentialMergeCommit"] = json!({"statusCheckRollup": {"state": state,
        "contexts": {"totalCount": ran.len(), "nodes": runs}}});
    node
}

#[test]
fn a_required_check_passing_on_the_test_merge_commit_is_not_missing() {
    let head = gated_node("SUCCESS", RAN, RAN.len(), &["Gate / Validate"]);
    let node = with_merge_commit(head, "SUCCESS", &["Gate / Validate"]);
    assert_eq!(gated_state("gated-merge-pass", node), Some(Checks::Passing));
}

#[test]
fn the_test_merge_commit_status_wins_over_the_head() {
    let head = gated_node("SUCCESS", RAN, RAN.len(), &[]);
    let node = with_merge_commit(head, "FAILURE", &["external"]);
    assert_eq!(gated_state("gated-merge-fail", node), Some(Checks::Failing));
}

#[test]
fn a_test_merge_commit_without_a_status_leaves_the_head_to_decide() {
    let mut node = gated_node("SUCCESS", RAN, RAN.len(), &["Gate / Validate"]);
    node["potentialMergeCommit"] = json!({"statusCheckRollup": null});
    assert_eq!(gated_state("gated-merge-none", node), Some(Checks::Pending));
}

#[test]
fn a_cut_off_check_list_cannot_prove_a_check_missing() {
    let node = gated_node("SUCCESS", RAN, 150, &["Gate / Validate"]);
    assert_eq!(gated_state("gated-cut-off", node), Some(Checks::Passing));
}

#[test]
fn a_failed_check_lookup_fails_every_id() {
    let gh = fake_gh("checks-down", "echo 'dial tcp: i/o timeout' >&2; exit 1");
    let fetch = gh.checks(&ids(&["PR_a", "PR_b"]));
    assert!(fetch.identity.is_none());
    assert_eq!(fetch.results.len(), 2);
    assert!(
        fetch
            .results
            .iter()
            .all(|(_, r)| matches!(r, Err(Error::Network(_))))
    );
}

/// A stand-in login shell: `body`, then the command it was given (`-l -i -c COMMAND`).
fn fake_shell(name: &str, body: &str) -> PathBuf {
    let path = scratch(name).join("shell");
    std::fs::write(
        &path,
        format!("#!/usr/bin/env bash\n{body}\nexec /bin/sh -c \"$4\"\n"),
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn var<'a>(vars: &'a [(OsString, OsString)], key: &str) -> Option<&'a str> {
    vars.iter()
        .find(|(k, _)| k == key)
        .and_then(|(_, v)| v.to_str())
}

#[test]
fn login_environment_is_read_past_rc_output() {
    let shell = fake_shell(
        "login-shell",
        "printf 'welcome, no newline'\nexport GH_HOST=example.test\nexport MULTI=$'two\\nlines'",
    );
    let vars = login::read(&shell, Duration::from_secs(10)).expect("environment");
    assert_eq!(var(&vars, "GH_HOST"), Some("example.test"));
    assert_eq!(var(&vars, "MULTI"), Some("two\nlines"));
    assert!(var(&vars, "PATH").is_some());
}

#[test]
fn login_environment_drops_output_after_env() {
    let parsed = login::parse(b"rc\ngh-inbox-environment\nA=1\0B=x=y\0junk").unwrap();
    assert_eq!(
        parsed,
        vec![("A".into(), "1".into()), ("B".into(), "x=y".into())]
    );
    assert_eq!(login::parse(b"A=1\0"), None);
}

#[test]
fn a_hung_or_failing_login_shell_gives_nothing() {
    let hung = fake_shell("hung-shell", "sleep 30");
    assert_eq!(login::read(&hung, Duration::from_millis(300)), None);
    let failing = fake_shell("failing-shell", "exit 1");
    assert_eq!(login::read(&failing, Duration::from_secs(10)), None);
}

#[test]
fn finds_gh_only_as_an_executable_file() {
    let dir = scratch("path-lookup");
    let path = std::env::join_paths([dir.clone()]).unwrap();
    let gh = dir.join("gh");
    let _ = std::fs::remove_file(&gh);
    assert!(!login::finds_gh(Some(&path)));
    std::fs::write(&gh, "").unwrap();
    assert!(!login::finds_gh(Some(&path)));
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(login::finds_gh(Some(&path)));
}

/// A fake `gh api --include` printing `headers`, a blank line and `body`.
fn including(name: &str, headers: &str, body: Value, code: i32) -> Gh {
    let file = scratch(name).join("response.txt");
    std::fs::write(&file, format!("HTTP/2.0 200 OK\r\n{headers}\r\n{body}")).unwrap();
    fake_gh(name, &format!("cat '{}'\nexit {code}", file.display()))
}

fn memberships(count: u64) -> Value {
    json!({"data": {
        "viewer": {"login": "me", "url": "https://github.com/me"},
        "memberships": {"organizations": {"totalCount": count}},
    }})
}

fn membership_of(name: &str, headers: &str, body: Value) -> Membership {
    including(name, headers, body, 0).membership().membership
}

#[test]
fn an_empty_membership_list_counts_only_with_an_org_scope() {
    for scope in ["read:org", "write:org", "admin:org"] {
        let headers = format!("X-Oauth-Scopes: gist, {scope}, repo\r\n");
        assert_eq!(
            membership_of(scope, &headers, memberships(0)),
            Membership::None
        );
    }
    let unrelated = "X-Oauth-Scopes: repo, user, read:packages\r\n";
    assert_eq!(
        membership_of("no-org-scope", unrelated, memberships(0)),
        Membership::Unknown
    );
    assert_eq!(
        membership_of("no-scope-header", "", memberships(0)),
        Membership::Unknown,
        "fine-grained tokens send no scopes"
    );
}

#[test]
fn any_membership_is_conclusive() {
    assert_eq!(
        membership_of("member", "", memberships(2)),
        Membership::Member
    );
}

#[test]
fn a_partial_or_failed_membership_check_is_unknown() {
    let scopes = "X-Oauth-Scopes: read:org\r\n";
    let mut partial = memberships(0);
    partial["errors"] = json!([{"message": "Resource not accessible by integration"}]);
    assert_eq!(
        membership_of("partial", scopes, partial),
        Membership::Unknown
    );
    let mut missing = memberships(0);
    missing["data"]["memberships"] = Value::Null;
    assert_eq!(
        membership_of("missing", scopes, missing),
        Membership::Unknown
    );
    let failed = fake_gh("membership-failed", "echo 'HTTP 502' >&2\nexit 1").membership();
    assert_eq!(
        (failed.identity, failed.membership),
        (None, Membership::Unknown)
    );
}

#[test]
fn membership_headers_parse_with_bare_newlines_too() {
    let file = scratch("lf").join("response.txt");
    std::fs::write(
        &file,
        format!(
            "HTTP/2.0 200 OK\nX-Oauth-Scopes: read:org\n\n{}",
            memberships(0)
        ),
    )
    .unwrap();
    let gh = fake_gh("lf", &format!("cat '{}'", file.display()));
    let fetch = gh.membership();
    assert_eq!(fetch.membership, Membership::None);
    assert_eq!(fetch.identity.unwrap().login, "me", "names its account");
}

#[test]
fn the_membership_check_asks_gh_for_headers() {
    let args = scratch("membership-args").join("args");
    let gh = fake_gh(
        "membership-args",
        &format!("printf '%s\\n' \"$@\" > '{}'", args.display()),
    );
    gh.membership();
    let args = std::fs::read_to_string(args).unwrap();
    assert!(args.starts_with("api\n--include\ngraphql\n-f\nquery="));
    assert!(args.contains("organizations(first: 1) { totalCount }"));
}
