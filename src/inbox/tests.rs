use super::*;
use crate::github::{Owner, Page, Repository, ReviewRoute};

fn me() -> Identity {
    Identity {
        login: "me".into(),
        host: "github.com".into(),
    }
}

fn someone_else() -> Identity {
    Identity {
        login: "work-me".into(),
        ..me()
    }
}

fn issue(url: &str) -> Item {
    Item {
        id: url.into(),
        number: 1,
        title: "t".into(),
        repository: Repository {
            name: "r".into(),
            name_with_owner: "o/r".into(),
            owner: None,
        },
        is_pull_request: false,
        is_draft: false,
        head: None,
        review: None,
        review_route: None,
        url: url.into(),
        updated_at: "2026-11-01T00:00:00Z".into(),
        author: "a".into(),
    }
}

fn pr(id: &str, head: &str) -> Item {
    Item {
        is_pull_request: true,
        head: Some(head.into()),
        ..issue(id)
    }
}

fn ok(items: Vec<Item>) -> SectionFetch {
    let n = items.len();
    SectionFetch {
        identity: Some(me()),
        page: Ok(Page {
            items,
            total: n as u64,
            truncated: false,
            returned: n,
        }),
        warnings: Vec::new(),
    }
}

fn truncated(items: Vec<Item>, total: u64) -> SectionFetch {
    let mut fetch = ok(items);
    if let Ok(page) = &mut fetch.page {
        page.truncated = true;
        page.total = total;
    }
    fetch
}

fn failed(err: Error) -> SectionFetch {
    SectionFetch {
        identity: Some(me()),
        page: Err(err),
        warnings: Vec::new(),
    }
}

fn gh_failed() -> SectionFetch {
    failed(Error::Gh("x".into()))
}

fn no_checks(ids: &[String]) -> Outcome {
    Outcome::Checks(ChecksFetch {
        identity: Some(me()),
        results: ids
            .iter()
            .map(|id| {
                let head = format!("{id}-head");
                (id.clone(), Ok(CheckState { head, checks: None }))
            })
            .collect(),
    })
}

fn member(membership: Membership) -> Outcome {
    Outcome::Membership(MembershipFetch {
        identity: Some(me()),
        membership,
    })
}

/// Starts every startable job, answering until none is left. Section `i`
/// gets `answers[i]`; a section without an answer, or a `None` from
/// `checks`, stays running.
fn drain(
    inbox: &mut Inbox,
    now: Instant,
    mut answers: Vec<Option<SectionFetch>>,
    mut checks: impl FnMut(&[String]) -> Option<Outcome>,
) -> Vec<Ticket> {
    let mut unanswered = Vec::new();
    while let Some(ticket) = inbox.next_job() {
        let outcome = match &ticket.job {
            Job::Section { index, .. } => answers
                .get_mut(*index)
                .and_then(Option::take)
                .map(Outcome::Section),
            Job::Checks { ids } => checks(ids),
            Job::Membership => Some(member(Membership::Member)),
        };
        match outcome {
            Some(outcome) => {
                inbox.finish(ticket, outcome, now);
            }
            None => unanswered.push(ticket),
        }
    }
    unanswered
}

/// A full refresh where every section answers and every PR has no checks.
fn refresh_with(inbox: &mut Inbox, now: Instant, answers: Vec<SectionFetch>) {
    inbox.refresh();
    let left = drain(inbox, now, answers.into_iter().map(Some).collect(), |ids| {
        Some(no_checks(ids))
    });
    assert!(left.is_empty(), "every job answered");
}

fn four(a: SectionFetch, b: SectionFetch) -> Vec<SectionFetch> {
    vec![a, b, ok(vec![]), ok(vec![])]
}

/// Answers the queued review fetch, and any check lookups it starts.
fn answer_review(inbox: &mut Inbox, fetch: SectionFetch) {
    let left = drain(inbox, Instant::now(), vec![Some(fetch)], |ids| {
        Some(no_checks(ids))
    });
    assert!(left.is_empty(), "every job answered");
}

fn urls(section: &SectionView) -> Vec<&str> {
    section.items.iter().map(|i| i.url.as_str()).collect()
}

fn owned(mut item: Item, typename: &str) -> Item {
    item.repository.owner = Some(Owner {
        typename: typename.into(),
    });
    item
}

#[test]
fn a_failed_section_keeps_its_items_size_and_says_why() {
    let t0 = Instant::now();
    let t1 = t0 + Duration::from_secs(120);
    let mut inbox = Inbox::default();
    refresh_with(&mut inbox, t0, four(ok(vec![issue("x")]), ok(vec![])));
    let err = Error::Server("502".into());
    refresh_with(&mut inbox, t1, four(failed(err.clone()), ok(vec![])));
    let a = &inbox.sections[0];
    assert_eq!(a.items.len(), 1);
    assert_eq!(a.error, Some(err));
    assert_eq!(a.fetched_at, Some(t0));
    assert_eq!(inbox.updated(), Some(t1), "other sections did arrive");
}

#[test]
fn recovery_clears_errors_and_never_loaded_is_not_empty() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    refresh_with(&mut inbox, t0, four(gh_failed(), ok(vec![])));
    assert!(!inbox.sections[0].loaded);
    assert!(inbox.sections[1].loaded);
    refresh_with(&mut inbox, t0, four(ok(vec![issue("y")]), ok(vec![])));
    assert_eq!(inbox.sections[0].error, None);
    assert!(inbox.sections[0].loaded);
}

#[test]
fn one_shared_failure_is_reported_once() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    let down = || failed(Error::Network("dial tcp".into()));
    refresh_with(&mut inbox, t0, vec![down(), down(), down(), down()]);
    assert_eq!(
        inbox.common_error(),
        Some(&Error::Network("dial tcp".into()))
    );
    assert!(!inbox.any_loaded());
    refresh_with(&mut inbox, t0, vec![down(), gh_failed(), down(), down()]);
    assert_eq!(
        inbox.common_error(),
        None,
        "different failures are shown apart"
    );
}

#[test]
fn sections_render_as_each_arrives() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    inbox.refresh();
    let left = drain(
        &mut inbox,
        t0,
        vec![None, Some(ok(vec![issue("x")]))],
        |_| None,
    );
    assert_eq!(left.len(), 3, "review, assigned and personal still running");
    assert!(inbox.sections[1].loaded && !inbox.sections[0].loaded);
    assert_eq!(inbox.visible()[1], [0]);
    assert!(inbox.any_busy());
}

#[test]
fn no_more_than_the_concurrency_limit_runs_and_sections_go_first() {
    let mut inbox = Inbox::default();
    inbox
        .checks_queued
        .extend(["PR_a".to_owned(), "PR_b".to_owned()]);
    inbox.refresh();
    let started: Vec<_> = std::iter::from_fn(|| inbox.next_job()).collect();
    assert_eq!(started.len(), CONCURRENCY);
    assert!(started.iter().all(|t| matches!(
        t.job,
        Job::Section {
            size: PAGE_STEP,
            ..
        }
    )));
    assert_eq!(inbox.refresh(), 0, "busy sections are not queued twice");
}

#[test]
fn a_new_account_clears_everything_and_drops_late_results() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    refresh_with(
        &mut inbox,
        t0,
        four(ok(vec![issue("x")]), ok(vec![issue("y")])),
    );
    inbox.refresh();
    let tickets: Vec<_> = std::iter::from_fn(|| inbox.next_job()).collect();
    let mut tickets = tickets.into_iter();

    let mut theirs = ok(vec![issue("z")]);
    theirs.identity = Some(someone_else());
    let first = tickets.next().unwrap();
    assert!(inbox.finish(first, Outcome::Section(theirs), t0));
    assert_eq!(inbox.identity, Some(someone_else()));
    assert_eq!(inbox.sections[0].items[0].url, "z");
    assert!(
        inbox.sections[1].items.is_empty(),
        "nothing of the old account survives"
    );

    // The old account's response, issued before the switch, arrives late.
    let late = tickets.next().unwrap();
    assert!(!inbox.finish(late, Outcome::Section(ok(vec![issue("y")])), t0));
    assert!(inbox.sections[1].items.is_empty());
    assert_eq!(inbox.identity, Some(someone_else()));
}

#[test]
fn a_check_lookup_from_another_account_also_resets() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    inbox.refresh();
    let left = drain(
        &mut inbox,
        t0,
        vec![Some(ok(vec![pr("PR_a", "h1")]))],
        |_| None,
    );
    let check = left
        .into_iter()
        .find(|t| matches!(t.job, Job::Checks { .. }))
        .unwrap();
    let theirs = Outcome::Checks(ChecksFetch {
        identity: Some(someone_else()),
        results: vec![("PR_a".into(), passing("h1"))],
    });
    assert!(inbox.finish(check, theirs, t0));
    assert!(!inbox.any_loaded());
    assert_eq!(inbox.check(&pr("PR_a", "h1")), Some(CheckView::Loading));
}

#[test]
fn a_failed_section_keeps_its_row_and_shows_the_newer_copy() {
    let t0 = Instant::now();
    let titled = |title: &str| Item {
        title: title.into(),
        ..issue("x")
    };
    let mut inbox = Inbox::default();
    refresh_with(&mut inbox, t0, four(ok(vec![titled("old")]), ok(vec![])));
    // Review fails and keeps x; authored now returns x freshly.
    refresh_with(
        &mut inbox,
        t0,
        four(gh_failed(), ok(vec![titled("new"), issue("y")])),
    );
    assert_eq!(inbox.visible()[..2], [vec![0], vec![1]]);
    assert_eq!(inbox.sections[0].items[0].title, "new");
}

#[test]
fn a_row_stays_put_while_every_section_fails() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    refresh_with(&mut inbox, t0, four(ok(vec![issue("x")]), ok(vec![])));
    refresh_with(&mut inbox, t0, four(gh_failed(), ok(vec![issue("x")])));
    assert_eq!(inbox.visible()[..2], [vec![0], vec![]]);
    refresh_with(&mut inbox, t0, four(gh_failed(), gh_failed()));
    assert_eq!(inbox.visible()[..2], [vec![0], vec![]]);
}

#[test]
fn one_round_falls_back_to_section_order_whatever_arrives_first() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    inbox.refresh();
    // Authored answers first, then review, both with x.
    drain(
        &mut inbox,
        t0,
        vec![None, Some(ok(vec![issue("x")]))],
        |_| None,
    );
    let review = Ticket {
        job: Job::Section {
            index: 0,
            size: PAGE_STEP,
            direct_only: false,
        },
        epoch: inbox.epoch,
        round: inbox.round,
    };
    inbox.finish(review, Outcome::Section(ok(vec![issue("x")])), t0);
    assert_eq!(inbox.visible()[..2], [vec![0], vec![]]);
}

#[test]
fn stale_items_not_refetched_elsewhere_stay_visible() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    refresh_with(&mut inbox, t0, four(ok(vec![issue("x")]), ok(vec![])));
    refresh_with(&mut inbox, t0, four(gh_failed(), ok(vec![])));
    assert_eq!(inbox.visible()[0], [0]);
}

#[test]
fn load_more_grows_one_section_and_refreshes_keep_the_size() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    assert!(!inbox.load_more(1), "nothing to load yet");
    refresh_with(
        &mut inbox,
        t0,
        four(ok(vec![]), truncated(vec![issue("x")], 60)),
    );
    assert!(inbox.load_more(1));
    assert!(!inbox.load_more(1), "already loading");
    let ticket = inbox.next_job().unwrap();
    assert_eq!(
        ticket.job,
        Job::Section {
            index: 1,
            size: 50,
            direct_only: false
        }
    );
    assert!(inbox.next_job().is_none(), "only that section");

    // A failed expansion keeps the rows and the last size that worked.
    inbox.finish(ticket, Outcome::Section(gh_failed()), t0);
    assert_eq!(inbox.sections[1].size, PAGE_STEP);
    assert_eq!(inbox.sections[1].items.len(), 1);

    assert!(inbox.load_more(1));
    let ticket = inbox.next_job().unwrap();
    let grown = truncated(vec![issue("x"), issue("y")], 60);
    inbox.finish(ticket, Outcome::Section(grown), t0);
    assert_eq!(inbox.sections[1].size, 50);

    inbox.refresh();
    let sizes: Vec<_> = std::iter::from_fn(|| inbox.next_job())
        .map(|t| t.job)
        .collect();
    assert!(sizes.contains(&Job::Section {
        index: 1,
        size: 50,
        direct_only: false
    }));
    assert!(sizes.contains(&Job::Section {
        index: 0,
        size: PAGE_STEP,
        direct_only: false
    }));
}

#[test]
fn an_expanded_section_refreshes_a_duplicate_shown_earlier() {
    let t0 = Instant::now();
    let titled = |title: &str| Item {
        title: title.into(),
        ..issue("x")
    };
    let mut inbox = Inbox::default();
    refresh_with(
        &mut inbox,
        t0,
        four(ok(vec![titled("old")]), truncated(vec![titled("old")], 60)),
    );
    assert_eq!(inbox.visible()[..2], [vec![0], vec![]]);
    assert!(inbox.load_more(1));
    let ticket = inbox.next_job().unwrap();
    let grown = truncated(vec![titled("new"), issue("y")], 60);
    inbox.finish(ticket, Outcome::Section(grown), t0);
    assert_eq!(inbox.visible()[..2], [vec![0], vec![1]], "first match wins");
    assert_eq!(inbox.sections[0].items[0].title, "new", "the newer copy");
}

#[test]
fn load_more_stops_at_githubs_page_limit() {
    let mut section = SectionView::new("s");
    section.truncated = true;
    section.size = PAGE_MAX;
    assert!(!section.can_load_more(), "past this, the search link");
    section.size = PAGE_MAX - PAGE_STEP;
    assert!(section.can_load_more());
}

#[test]
fn direct_only_requeues_the_review_section_and_every_job_carries_it() {
    let mut inbox = Inbox::default();
    inbox.refresh();
    let unanswered = drain(
        &mut inbox,
        Instant::now(),
        vec![None, None, None, None],
        |_| None,
    );
    for ticket in unanswered {
        inbox.finish(ticket, Outcome::Section(ok(vec![])), Instant::now());
    }

    assert!(!inbox.review_direct_only());
    assert!(inbox.set_review_direct_only(true));
    assert!(inbox.review_direct_only());
    assert!(
        !inbox.set_review_direct_only(true),
        "no change, nothing requeued"
    );

    let ticket = inbox.next_job().unwrap();
    assert_eq!(
        ticket.job,
        Job::Section {
            index: REVIEW_SECTION,
            size: PAGE_STEP,
            direct_only: true,
        }
    );
}

#[test]
fn a_review_fetch_started_before_the_toggle_is_refetched_not_shown() {
    let mut inbox = Inbox::default();
    inbox.refresh();
    let in_flight = inbox.next_job().unwrap();
    assert!(inbox.set_review_direct_only(true));

    inbox.finish(
        in_flight,
        Outcome::Section(ok(vec![issue("stale")])),
        Instant::now(),
    );
    assert!(inbox.sections[REVIEW_SECTION].items.is_empty());
    let retried = std::iter::from_fn(|| inbox.next_job())
        .map(|t| t.job)
        .find(|job| {
            matches!(
                job,
                Job::Section {
                    index: REVIEW_SECTION,
                    ..
                }
            )
        });
    assert_eq!(
        retried,
        Some(Job::Section {
            index: REVIEW_SECTION,
            size: PAGE_STEP,
            direct_only: true,
        })
    );
}

#[test]
fn turning_direct_only_on_never_shows_the_team_requests() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    refresh_with(
        &mut inbox,
        t0,
        four(
            truncated(vec![issue("direct"), issue("team")], 60),
            ok(vec![]),
        ),
    );
    assert!(inbox.set_review_direct_only(true));
    let review = &inbox.sections[REVIEW_SECTION];
    assert!(review.items.is_empty() && !review.loaded && !review.truncated);

    answer_review(&mut inbox, gh_failed());
    let review = &inbox.sections[REVIEW_SECTION];
    assert!(
        review.items.is_empty() && !review.loaded,
        "nothing from the other search"
    );
    assert_eq!((review.total, review.size), (0, PAGE_STEP));
    assert_eq!(review.error, Some(Error::Gh("x".into())));
}

#[test]
fn each_review_mode_keeps_its_own_last_good_rows() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    refresh_with(
        &mut inbox,
        t0,
        four(ok(vec![issue("direct"), issue("team")]), ok(vec![])),
    );
    assert!(inbox.set_review_direct_only(true));
    answer_review(&mut inbox, ok(vec![issue("direct")]));

    assert!(inbox.set_review_direct_only(false));
    assert_eq!(urls(&inbox.sections[REVIEW_SECTION]), ["direct", "team"]);
    answer_review(&mut inbox, gh_failed());
    let review = &inbox.sections[REVIEW_SECTION];
    assert_eq!(
        urls(review),
        ["direct", "team"],
        "a failure keeps this mode's rows"
    );
    assert!(review.error.is_some());

    assert!(inbox.set_review_direct_only(true));
    let review = &inbox.sections[REVIEW_SECTION];
    assert_eq!(urls(review), ["direct"]);
    assert!(review.error.is_none());
    answer_review(&mut inbox, gh_failed());
    let review = &inbox.sections[REVIEW_SECTION];
    assert_eq!(urls(review), ["direct"]);
    assert!(review.error.is_some());
}

#[test]
fn a_superseded_failure_stays_with_its_own_mode() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    inbox.refresh();
    let in_flight = inbox.next_job().unwrap();
    assert!(inbox.set_review_direct_only(true));
    inbox.finish(in_flight, Outcome::Section(gh_failed()), t0);
    let review = &inbox.sections[REVIEW_SECTION];
    assert!(review.error.is_none());

    let answers = four(ok(vec![issue("d")]), ok(vec![]));
    drain(
        &mut inbox,
        t0,
        answers.into_iter().map(Some).collect(),
        |ids| Some(no_checks(ids)),
    );
    let review = &inbox.sections[REVIEW_SECTION];
    assert_eq!(urls(review), ["d"]);
    assert!(review.error.is_none());

    assert!(inbox.set_review_direct_only(false));
    let review = &inbox.sections[REVIEW_SECTION];
    assert_eq!(review.error, Some(Error::Gh("x".into())));
}

/// Check lookups that find every PR at `head`.
fn checks_at(head: &'static str) -> impl FnMut(&[String]) -> Option<Outcome> {
    move |ids| {
        Some(Outcome::Checks(ChecksFetch {
            identity: Some(me()),
            results: ids
                .iter()
                .map(|id| {
                    let state = CheckState {
                        head: head.into(),
                        checks: Some(Checks::Passing),
                    };
                    (id.clone(), Ok(state))
                })
                .collect(),
        }))
    }
}

#[test]
fn a_restored_review_mode_does_not_expect_its_older_head() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    inbox.refresh();
    let answers = four(ok(vec![pr("x", "A")]), ok(vec![]));
    drain(
        &mut inbox,
        t0,
        answers.into_iter().map(Some).collect(),
        checks_at("A"),
    );
    assert!(inbox.set_review_direct_only(true));
    drain(&mut inbox, t0, vec![Some(ok(vec![]))], checks_at("A"));
    inbox.refresh();
    let answers = four(ok(vec![]), ok(vec![pr("x", "B")]));
    drain(
        &mut inbox,
        t0,
        answers.into_iter().map(Some).collect(),
        checks_at("B"),
    );

    // The full search's cached copy of x is still at A; authored's is newer.
    let before = screen(&inbox);
    assert!(inbox.set_review_direct_only(false));
    assert_eq!(
        inbox.visible()[..2],
        [vec![], vec![0]],
        "restoring moves nothing"
    );
    assert_eq!(screen(&inbox), before);
    drain(&mut inbox, t0, vec![Some(gh_failed())], checks_at("B"));
    assert_eq!(inbox.visible()[..2], [vec![], vec![0]]);
    assert_eq!(
        inbox.check(&pr("x", "B")),
        Some(CheckView::Known {
            checks: Some(Checks::Passing),
            stale: false
        })
    );
    assert_eq!(inbox.check_failures(), None);
}

#[test]
fn toggling_drops_a_review_fetch_still_waiting_for_a_slot() {
    let mut inbox = Inbox::default();
    inbox.refresh();
    assert!(inbox.set_review_direct_only(true));
    assert!(inbox.set_review_direct_only(false));
    let review_jobs: Vec<Job> = std::iter::from_fn(|| inbox.next_job())
        .map(|t| t.job)
        .filter(|job| {
            matches!(
                job,
                Job::Section {
                    index: REVIEW_SECTION,
                    ..
                }
            )
        })
        .collect();
    assert_eq!(
        review_jobs,
        [Job::Section {
            index: REVIEW_SECTION,
            size: PAGE_STEP,
            direct_only: false,
        }]
    );
}

#[test]
fn the_check_banner_counts_only_rows_the_owner_tab_shows() {
    let t0 = Instant::now();
    let org_err = Error::Server("502".into());
    let mine_err = Error::RateLimited("slow down".into());
    let org_a = owned(pr("org_a", "org_a-head"), "Organization");
    let org_b = owned(pr("org_b", "org_b-head"), "Organization");
    let mine_bad = owned(pr("mine_bad", "mine_bad-head"), "User");
    let mine_ok = owned(pr("mine_ok", "mine_ok-head"), "User");
    let mut inbox = Inbox::default();
    inbox.refresh();
    let answers = four(ok(vec![org_a, mine_bad]), ok(vec![org_b, mine_ok]));
    drain(
        &mut inbox,
        t0,
        answers.into_iter().map(Some).collect(),
        |ids| {
            Some(Outcome::Checks(ChecksFetch {
                identity: Some(me()),
                results: ids
                    .iter()
                    .map(|id| {
                        let result = match id.as_str() {
                            "mine_bad" => Err(mine_err.clone()),
                            _ if id.starts_with("org") => Err(org_err.clone()),
                            _ => Ok(CheckState {
                                head: format!("{id}-head"),
                                checks: None,
                            }),
                        };
                        (id.clone(), result)
                    })
                    .collect(),
            }))
        },
    );
    assert_eq!(inbox.check_failures(), Some((3, &org_err)));

    inbox.owner_filter = OwnerFilter::Personal;
    assert_eq!(
        inbox.check_failures(),
        Some((1, &mine_err)),
        "the example comes from a shown row"
    );
    inbox.owner_filter = OwnerFilter::Organization;
    assert_eq!(inbox.check_failures(), Some((2, &org_err)));

    inbox.owner_filter = OwnerFilter::All;
    assert_eq!(inbox.check_failures(), Some((3, &org_err)));
}

#[test]
fn failures_only_on_hidden_rows_raise_no_banner() {
    let (mut inbox, item) = with_check(Err(Error::Server("502".into())));
    assert!(item.repository.owner.is_none());
    inbox.owner_filter = OwnerFilter::Personal;
    assert_eq!(inbox.check_failures(), None);
    inbox.owner_filter = OwnerFilter::All;
    assert!(inbox.check_failures().is_some());
}

#[test]
fn checks_load_after_rows_in_batches() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    let prs: Vec<_> = (0..30).map(|n| pr(&format!("PR_{n}"), "h")).collect();
    inbox.refresh();
    let mut batches = Vec::new();
    drain(
        &mut inbox,
        t0,
        vec![Some(ok(prs.clone())), Some(ok(vec![issue("i")]))],
        |ids| {
            batches.push(ids.len());
            None
        },
    );
    assert_eq!(batches, [CHECK_BATCH, 30 - CHECK_BATCH]);
    assert_eq!(inbox.check(&prs[0]), Some(CheckView::Loading));
    assert_eq!(inbox.check(&issue("i")), None, "issues have no checks");
}

/// One PR shown under review, with its check lookups answered by `answer`.
fn with_check(answer: Result<CheckState, Error>) -> (Inbox, Item) {
    let t0 = Instant::now();
    let item = pr("PR_a", "h1");
    let mut inbox = Inbox::default();
    inbox.refresh();
    drain(&mut inbox, t0, vec![Some(ok(vec![item.clone()]))], |ids| {
        Some(Outcome::Checks(ChecksFetch {
            identity: Some(me()),
            results: ids.iter().map(|id| (id.clone(), answer.clone())).collect(),
        }))
    });
    (inbox, item)
}

fn passing(head: &str) -> Result<CheckState, Error> {
    Ok(CheckState {
        head: head.into(),
        checks: Some(Checks::Passing),
    })
}

#[test]
fn a_known_check_is_shown_for_its_head_commit_only() {
    let (inbox, item) = with_check(passing("h1"));
    assert_eq!(
        inbox.check(&item),
        Some(CheckView::Known {
            checks: Some(Checks::Passing),
            stale: false
        })
    );
    let pushed = pr("PR_a", "h2");
    assert_eq!(
        inbox.check(&pushed),
        Some(CheckView::Loading),
        "a new commit's checks are unknown, not the old commit's"
    );
}

#[test]
fn a_pending_recheck_keeps_the_dot_as_it_was() {
    let (mut inbox, item) = with_check(passing("h1"));
    inbox.refresh();
    let left = drain(
        &mut inbox,
        Instant::now(),
        vec![Some(ok(vec![item.clone()]))],
        |_| None,
    );
    assert!(!left.is_empty(), "the recheck is still running");
    assert_eq!(
        inbox.check(&item),
        Some(CheckView::Known {
            checks: Some(Checks::Passing),
            stale: false
        })
    );
}

#[test]
fn a_failed_lookup_stays_shown_while_rechecked_until_a_new_head() {
    let t0 = Instant::now();
    let err = Error::Server("502".into());
    let item = pr("PR_a", "h1");
    let all = |items: Vec<Item>| four(ok(items), ok(vec![])).into_iter().map(Some).collect();
    let mut inbox = Inbox::default();
    inbox.refresh();
    drain(&mut inbox, t0, all(vec![item.clone()]), |ids| {
        Some(Outcome::Checks(ChecksFetch {
            identity: Some(me()),
            results: ids
                .iter()
                .map(|id| (id.clone(), Err(err.clone())))
                .collect(),
        }))
    });

    inbox.refresh();
    let left = drain(&mut inbox, t0, all(vec![item.clone()]), |_| None);
    assert_eq!(left.len(), 1, "the recheck is still running");
    assert_eq!(inbox.check(&item), Some(CheckView::Failed(err.clone())));
    assert_eq!(inbox.check_failures(), Some((1, &err)), "no banner flash");

    let moved = pr("PR_a", "h2");
    inbox.refresh();
    drain(&mut inbox, t0, all(vec![moved.clone()]), |_| None);
    assert_eq!(
        inbox.check(&moved),
        Some(CheckView::Loading),
        "a new commit"
    );
    assert_eq!(inbox.check_failures(), None);
}

#[test]
fn a_failed_lookup_is_shown_and_counted() {
    let err = Error::Server("502".into());
    let (inbox, item) = with_check(Err(err.clone()));
    assert_eq!(inbox.check(&item), Some(CheckView::Failed(err.clone())));
    assert_eq!(inbox.check_failures(), Some((1, &err)));
}

#[test]
fn a_failed_recheck_keeps_the_old_state_marked_stale() {
    let (mut inbox, item) = with_check(passing("h1"));
    inbox.refresh();
    drain(
        &mut inbox,
        Instant::now(),
        vec![Some(ok(vec![item.clone()]))],
        |ids| {
            Some(Outcome::Checks(ChecksFetch {
                identity: None,
                results: ids
                    .iter()
                    .map(|id| (id.clone(), Err(Error::Network("down".into()))))
                    .collect(),
            }))
        },
    );
    assert_eq!(
        inbox.check(&item),
        Some(CheckView::Known {
            checks: Some(Checks::Passing),
            stale: true
        })
    );
}

#[test]
fn scheduling_follows_focus() {
    let s = Duration::from_secs;
    assert!(due(Trigger::Tick, true, None), "first load");
    assert!(!due(Trigger::Tick, true, Some(s(119))));
    assert!(due(Trigger::Tick, true, Some(s(120))));
    assert!(!due(Trigger::Tick, false, Some(s(599))));
    assert!(due(Trigger::Tick, false, Some(s(600))));
    assert!(!due(Trigger::Focus, true, Some(s(29))));
    assert!(due(Trigger::Focus, true, Some(s(30))));
    assert!(!due(Trigger::Focus, false, Some(s(3600))));
}

#[test]
fn ages_read_naturally() {
    let t = Instant::now();
    assert_eq!(ago(t, t + Duration::from_secs(59)), "just now");
    assert_eq!(ago(t, t + Duration::from_secs(250)), "4m ago");
    assert_eq!(ago(t, t + Duration::from_secs(7300)), "2h ago");
}

#[test]
fn a_head_change_during_a_lookup_is_followed_up() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    inbox.refresh();
    let answers = four(ok(vec![pr("PR_a", "h1")]), ok(vec![]));
    let left = drain(
        &mut inbox,
        t0,
        answers.into_iter().map(Some).collect(),
        |_| None,
    );
    let [lookup] = <[Ticket; 1]>::try_from(left).unwrap();

    // A push lands; the next refresh shows h2 while the h1 lookup still runs.
    refresh_with_pending(&mut inbox, t0, four(ok(vec![pr("PR_a", "h2")]), ok(vec![])));
    let theirs = Outcome::Checks(ChecksFetch {
        identity: Some(me()),
        results: vec![("PR_a".into(), passing("h1"))],
    });
    inbox.finish(lookup, theirs, t0);
    let shown = pr("PR_a", "h2");
    assert_eq!(inbox.check(&shown), Some(CheckView::Loading));
    let follow_up = inbox.next_job().expect("loading means a lookup is queued");
    assert_eq!(
        follow_up.job,
        Job::Checks {
            ids: ids(&["PR_a"])
        }
    );
    let answer = Outcome::Checks(ChecksFetch {
        identity: Some(me()),
        results: vec![("PR_a".into(), passing("h2"))],
    });
    inbox.finish(follow_up, answer, t0);
    assert_eq!(
        inbox.check(&shown),
        Some(CheckView::Known {
            checks: Some(Checks::Passing),
            stale: false
        })
    );
}

#[test]
fn checks_for_an_unexpected_commit_fail_rather_than_load_forever() {
    let (inbox, item) = with_check(passing("h9"));
    assert_eq!(
        inbox.check(&item),
        Some(CheckView::Failed(Error::OtherCommit))
    );
    assert!(inbox.checks_pending.is_empty(), "nothing left to load");
}

/// A full refresh answering every section; check lookups are left queued.
fn refresh_with_pending(inbox: &mut Inbox, now: Instant, answers: Vec<SectionFetch>) {
    inbox.refresh();
    let mut answers: Vec<_> = answers.into_iter().map(Some).collect();
    while let Some(ticket) = inbox.next_job() {
        let Job::Section { index, .. } = ticket.job else {
            panic!("only sections expected");
        };
        let outcome = Outcome::Section(answers[index].take().unwrap());
        inbox.finish(ticket, outcome, now);
    }
}

fn ids(names: &[&str]) -> Vec<String> {
    names.iter().map(|&n| n.to_owned()).collect()
}

/// Starts jobs until the membership check, answering every section empty.
fn answer_membership(inbox: &mut Inbox, membership: Membership) {
    loop {
        let ticket = inbox.next_job().expect("the membership check is queued");
        let outcome = match ticket.job {
            Job::Membership => {
                inbox.finish(ticket, member(membership), Instant::now());
                return;
            }
            Job::Section { .. } => Outcome::Section(ok(vec![])),
            Job::Checks { ref ids } => no_checks(ids),
        };
        inbox.finish(ticket, outcome, Instant::now());
    }
}

#[test]
fn direct_only_shows_unless_membership_rules_teams_out() {
    for (membership, shown) in [
        (Membership::None, false),
        (Membership::Member, true),
        (Membership::Unknown, true),
    ] {
        let mut inbox = Inbox::default();
        assert!(!inbox.show_direct_only(), "hidden until answered");
        inbox.refresh();
        answer_membership(&mut inbox, membership);
        assert_eq!(inbox.show_direct_only(), shown, "{membership:?}");
        inbox.refresh();
        let asked_again = std::iter::from_fn(|| inbox.next_job()).any(|t| t.job == Job::Membership);
        assert!(!asked_again, "once per account");
    }
}

#[test]
fn a_membership_answer_for_the_old_account_is_dropped() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    inbox.refresh();
    let mut tickets: Vec<Ticket> = std::iter::from_fn(|| inbox.next_job()).collect();
    let first = tickets.remove(0);
    inbox.finish(first, Outcome::Section(ok(vec![])), t0);
    let membership = inbox.next_job().unwrap();
    assert_eq!(membership.job, Job::Membership);

    let theirs = SectionFetch {
        identity: Some(someone_else()),
        ..ok(vec![])
    };
    assert!(inbox.finish(tickets.remove(0), Outcome::Section(theirs), t0));
    inbox.finish(membership, member(Membership::None), t0);
    assert!(!inbox.show_direct_only());
    assert_eq!(inbox.membership, MembershipCheck::Due, "asked again");
}

#[test]
fn a_new_account_starts_with_default_filters() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    refresh_with(&mut inbox, t0, four(ok(vec![]), ok(vec![])));
    assert!(inbox.set_review_direct_only(true));
    inbox.owner_filter = OwnerFilter::Personal;
    inbox.mixed_owners = true;
    let ticket = inbox.next_job().unwrap();
    let theirs = SectionFetch {
        identity: Some(someone_else()),
        ..ok(vec![])
    };
    assert!(inbox.finish(ticket, Outcome::Section(theirs), t0));
    assert!(!inbox.review_direct_only());
    assert_eq!(inbox.owner_filter, OwnerFilter::All);
    assert!(!inbox.show_owner_tabs() && !inbox.show_direct_only());
}

#[test]
fn owner_tabs_appear_once_both_owner_types_load_and_stay() {
    let t0 = Instant::now();
    let org = || owned(issue("org"), "Organization");
    let mine = || owned(issue("mine"), "User");
    let mut inbox = Inbox::default();
    refresh_with(&mut inbox, t0, four(gh_failed(), ok(vec![])));
    assert!(!inbox.show_owner_tabs(), "nothing loaded");
    refresh_with(&mut inbox, t0, four(truncated(vec![org()], 30), ok(vec![])));
    assert!(!inbox.show_owner_tabs(), "one owner type");

    inbox.owner_filter = OwnerFilter::Personal;
    assert!(inbox.load_more(REVIEW_SECTION));
    let left = drain(&mut inbox, t0, vec![Some(ok(vec![org(), mine()]))], |ids| {
        Some(no_checks(ids))
    });
    assert!(left.is_empty());
    assert!(inbox.show_owner_tabs(), "revealed by a later page");

    refresh_with(&mut inbox, t0, four(ok(vec![org()]), ok(vec![])));
    assert!(inbox.show_owner_tabs(), "kept for the account");
}

/// Everything a refresh could visibly change in the list.
fn screen(inbox: &Inbox) -> String {
    let visible = inbox.visible();
    let rows: Vec<String> = inbox
        .sections
        .iter()
        .zip(&visible)
        .map(|(section, shown)| {
            let items: Vec<String> = shown
                .iter()
                .map(|&i| {
                    let item = &section.items[i];
                    format!("{}@{:?}:{:?}", item.url, item.head, inbox.check(item))
                })
                .collect();
            format!(
                "{} [{}] error={:?} more={}/{}",
                section.name,
                items.join(", "),
                section.error,
                section.can_load_more(),
                section.expanding
            )
        })
        .collect();
    format!("{rows:#?} banner={:?}", inbox.check_failures())
}

/// Checks answer `ok` for every PR except `bad`, which fails.
fn checks_with_one_failure(ids: &[String]) -> Option<Outcome> {
    Some(Outcome::Checks(ChecksFetch {
        identity: Some(me()),
        results: ids
            .iter()
            .map(|id| {
                let result = if id == "bad" {
                    Err(Error::Server("502".into()))
                } else {
                    passing(&format!("{id}-head"))
                };
                (id.clone(), result)
            })
            .collect(),
    }))
}

fn sample() -> Vec<SectionFetch> {
    let shared = pr("shared", "shared-head");
    four(
        truncated(vec![shared.clone(), pr("bad", "bad-head")], 40),
        ok(vec![shared, pr("mine", "mine-head")]),
    )
}

/// Starts a refresh, then answers its sections one at a time in `order`,
/// returning the screen after each answer; check lookups stay running.
fn refresh_one_by_one(
    inbox: &mut Inbox,
    answers: Vec<SectionFetch>,
    order: &[usize],
) -> Vec<String> {
    inbox.refresh();
    let mut tickets: Vec<Ticket> = std::iter::from_fn(|| inbox.next_job())
        .filter(|t| matches!(t.job, Job::Section { .. }))
        .collect();
    let mut answers: Vec<Option<SectionFetch>> = answers.into_iter().map(Some).collect();
    let mut screens = vec![screen(inbox)];
    for &index in order {
        let at = tickets
            .iter()
            .position(|t| matches!(t.job, Job::Section { index: i, .. } if i == index))
            .unwrap();
        let ticket = tickets.remove(at);
        let fetch = answers[index].take().unwrap();
        inbox.finish(ticket, Outcome::Section(fetch), Instant::now());
        screens.push(screen(inbox));
    }
    screens
}

#[test]
fn an_identical_refresh_changes_nothing_on_screen_at_any_point() {
    let mut inbox = Inbox::default();
    inbox.refresh();
    let answers = sample().into_iter().map(Some).collect();
    drain(&mut inbox, Instant::now(), answers, checks_with_one_failure);
    let before = screen(&inbox);
    assert!(
        before.contains("Server"),
        "a failed check is part of the test"
    );

    // Authored answers first: its fresh copy of `shared` must not pull the
    // row out of review while review is still loading.
    for screen in refresh_one_by_one(&mut inbox, sample(), &[1, 2, 3, 0]) {
        assert_eq!(screen, before);
    }
}

/// `screen` without each section's error.
fn rows_and_dots(inbox: &Inbox) -> String {
    without_errors(&screen(inbox))
}

fn without_errors(screen: &str) -> String {
    screen
        .lines()
        .map(|line| line.split(" error=").next().unwrap_or(line))
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn a_failed_refresh_changes_only_that_sections_status() {
    let mut inbox = Inbox::default();
    inbox.refresh();
    let answers = sample().into_iter().map(Some).collect();
    drain(&mut inbox, Instant::now(), answers, checks_with_one_failure);
    let before = rows_and_dots(&inbox);

    let mut answers = sample();
    answers[1] = gh_failed();
    refresh_one_by_one(&mut inbox, answers, &[0, 1, 2, 3]);
    assert_eq!(rows_and_dots(&inbox), before);
    let errors: Vec<bool> = inbox.sections.iter().map(|s| s.error.is_some()).collect();
    assert_eq!(errors, [false, true, false, false]);
}

#[test]
fn a_changed_refresh_touches_only_the_changed_rows() {
    let mut inbox = Inbox::default();
    inbox.refresh();
    let answers = sample().into_iter().map(Some).collect();
    drain(&mut inbox, Instant::now(), answers, checks_with_one_failure);

    let mut answers = sample();
    answers[1] = ok(vec![pr("shared", "shared-head"), pr("new", "new-head")]);
    refresh_one_by_one(&mut inbox, answers, &[0, 1, 2, 3]);
    let visible = inbox.visible();
    let urls_shown = |s: usize| -> Vec<&str> {
        visible[s]
            .iter()
            .map(|&i| inbox.sections[s].items[i].url.as_str())
            .collect()
    };
    assert_eq!(urls_shown(0), ["shared", "bad"], "untouched");
    assert_eq!(urls_shown(1), ["new"], "mine left, new arrived");
    let shared = pr("shared", "shared-head");
    assert_eq!(
        inbox.check(&shared),
        Some(CheckView::Known {
            checks: Some(Checks::Passing),
            stale: false
        })
    );
}

#[test]
fn load_more_during_a_refresh_waits_for_it_then_runs() {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    refresh_with(
        &mut inbox,
        t0,
        four(truncated(vec![issue("a")], 60), ok(vec![])),
    );
    inbox.refresh();
    assert!(
        !inbox.sections[0].expanding,
        "a refresh alone isn't loading more"
    );
    assert!(inbox.load_more(0));
    assert!(!inbox.load_more(0), "asked once");
    let refresh = inbox.next_job().unwrap();
    assert!(matches!(
        refresh.job,
        Job::Section {
            index: 0,
            size: PAGE_STEP,
            ..
        }
    ));
    inbox.finish(
        refresh,
        Outcome::Section(truncated(vec![issue("a")], 60)),
        t0,
    );
    assert!(inbox.sections[0].expanding);
    let sizes: Vec<u32> = std::iter::from_fn(|| inbox.next_job())
        .filter_map(|t| match t.job {
            Job::Section { index: 0, size, .. } => Some(size),
            _ => None,
        })
        .collect();
    assert_eq!(sizes, [2 * PAGE_STEP]);
}

/// x shown in review, whose fetch failed after its copy at commit A, while
/// authored has a newer copy at B.
fn split_rounds() -> Inbox {
    let t0 = Instant::now();
    let mut inbox = Inbox::default();
    inbox.refresh();
    let answers = four(ok(vec![pr("x", "A")]), ok(vec![]));
    drain(
        &mut inbox,
        t0,
        answers.into_iter().map(Some).collect(),
        checks_at("A"),
    );
    inbox.refresh();
    let answers = four(gh_failed(), ok(vec![pr("x", "B")]));
    drain(
        &mut inbox,
        t0,
        answers.into_iter().map(Some).collect(),
        checks_at("B"),
    );
    assert_eq!(inbox.visible()[..2], [vec![0], vec![]]);
    assert_eq!(inbox.sections[0].items[0].head.as_deref(), Some("B"));
    inbox
}

#[test]
fn starting_or_failing_a_refresh_changes_nothing_shown() {
    let mut inbox = split_rounds();
    let before = screen(&inbox);
    let answers = four(gh_failed(), ok(vec![pr("x", "B")]));
    for screen in refresh_one_by_one(&mut inbox, answers, &[0, 1, 2, 3]) {
        assert_eq!(screen, before);
    }
}

#[test]
fn a_row_moves_only_when_a_successful_fetch_drops_it() {
    let mut inbox = split_rounds();
    let before = rows_and_dots(&inbox);
    let answers = four(ok(vec![]), ok(vec![pr("x", "B")]));
    let screens = refresh_one_by_one(&mut inbox, answers, &[1, 2, 3, 0]);
    assert_eq!(screens.len(), 5);
    for screen in &screens[..4] {
        assert_eq!(
            without_errors(screen),
            before,
            "nothing moves before review answers"
        );
    }
    assert_eq!(
        inbox.visible()[..2],
        [vec![], vec![0]],
        "review no longer has x"
    );
}

#[test]
fn a_failed_section_keeps_its_row_review_route_and_takes_newer_data() {
    let t0 = Instant::now();
    let requested = Item {
        title: "old".into(),
        review_route: Some(ReviewRoute::Team("platform".into())),
        ..pr("x", "A")
    };
    let mut inbox = Inbox::default();
    inbox.refresh();
    let answers = four(ok(vec![requested]), ok(vec![pr("x", "A")]));
    drain(
        &mut inbox,
        t0,
        answers.into_iter().map(Some).collect(),
        checks_at("A"),
    );

    let pushed = Item {
        title: "new".into(),
        ..pr("x", "B")
    };
    inbox.refresh();
    let answers = four(gh_failed(), ok(vec![pushed]));
    drain(
        &mut inbox,
        t0,
        answers.into_iter().map(Some).collect(),
        checks_at("B"),
    );
    assert_eq!(inbox.visible()[..2], [vec![0], vec![]], "still in review");
    let shown = &inbox.sections[0].items[0];
    assert_eq!(
        (shown.title.as_str(), shown.head.as_deref()),
        ("new", Some("B"))
    );
    assert_eq!(
        shown.review_route,
        Some(ReviewRoute::Team("platform".into())),
        "authored's copy has no route to give"
    );
    assert_eq!(
        inbox.check(shown),
        Some(CheckView::Known {
            checks: Some(Checks::Passing),
            stale: false
        })
    );
    assert!(inbox.sections[0].error.is_some());
}

#[test]
fn copied_data_keeps_its_own_freshness() {
    let t0 = Instant::now();
    let shown_head = |inbox: &Inbox| -> Vec<(usize, Option<String>)> {
        let visible = inbox.visible();
        (0..3)
            .flat_map(|s| {
                visible[s]
                    .iter()
                    .map(move |&i| (s, inbox.sections[s].items[i].head.clone()))
            })
            .collect()
    };
    let mut inbox = Inbox::default();
    // Round 1: review has A. Round 2: review fails, assigned has A.
    refresh_with(
        &mut inbox,
        t0,
        vec![ok(vec![pr("x", "A")]), ok(vec![]), ok(vec![]), ok(vec![])],
    );
    refresh_with(
        &mut inbox,
        t0,
        vec![gh_failed(), ok(vec![]), ok(vec![pr("x", "A")]), ok(vec![])],
    );
    // Round 3: authored brings B; review shows it in place.
    refresh_with(
        &mut inbox,
        t0,
        vec![gh_failed(), ok(vec![pr("x", "B")]), gh_failed(), ok(vec![])],
    );
    assert_eq!(shown_head(&inbox), [(0, Some("B".to_owned()))]);
    // Round 4: authored drops x while review and assigned fail.
    refresh_with(
        &mut inbox,
        t0,
        vec![gh_failed(), ok(vec![]), gh_failed(), ok(vec![])],
    );
    assert_eq!(
        shown_head(&inbox),
        [(0, Some("B".to_owned()))],
        "assigned's round-2 copy is older than B"
    );
}
