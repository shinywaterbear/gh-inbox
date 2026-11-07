//! What the window shows, independent of GPUI: the last good results per
//! section, which requests to run next, their outcomes, and when to refresh.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use crate::github::{
    CheckState, Checks, ChecksFetch, Error, Identity, Item, Membership, MembershipFetch, OwnerKind,
    REVIEW_SECTION, SECTIONS, SectionFetch,
};

/// Automatic refresh cadence; a manual refresh ignores all of these.
pub const FOCUSED_INTERVAL: Duration = Duration::from_secs(2 * 60);
pub const BLURRED_INTERVAL: Duration = Duration::from_secs(10 * 60);
/// Focusing the window refreshes only when the last attempt is at least this old.
pub const FOCUS_MIN_AGE: Duration = Duration::from_secs(30);
/// gh calls running at once, sections and checks together.
pub const CONCURRENCY: usize = 4;
/// A section's first page, and how much each "load more" adds.
pub const PAGE_STEP: u32 = 25;
/// GitHub's largest page; past it a section links to the full search.
pub const PAGE_MAX: u32 = 100;
/// PRs per check lookup.
pub const CHECK_BATCH: usize = 25;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trigger {
    Tick,
    Focus,
}

/// Whether an automatic refresh is due. `since_attempt` counts failures too,
/// so a failing refresh is retried at the normal cadence, not in a loop.
pub fn due(trigger: Trigger, focused: bool, since_attempt: Option<Duration>) -> bool {
    let Some(age) = since_attempt else {
        return true;
    };
    match trigger {
        Trigger::Focus => focused && age >= FOCUS_MIN_AGE,
        Trigger::Tick if focused => age >= FOCUSED_INTERVAL,
        Trigger::Tick => age >= BLURRED_INTERVAL,
    }
}

/// A client-side split by repository owner type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OwnerFilter {
    All,
    Personal,
    Organization,
}

impl OwnerFilter {
    /// An unclassified repository matches neither Personal nor Organization.
    pub fn matches(self, item: &Item) -> bool {
        match self {
            Self::All => true,
            Self::Personal => item.repository.owner_kind() == OwnerKind::Personal,
            Self::Organization => item.repository.owner_kind() == OwnerKind::Organization,
        }
    }
}

/// One gh call to make. `direct_only` is set only for `REVIEW_SECTION`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Job {
    Section {
        index: usize,
        size: u32,
        direct_only: bool,
    },
    Checks {
        ids: Vec<String>,
    },
    Membership,
}

/// A started job, handed back with its outcome.
#[derive(Debug, Clone)]
pub struct Ticket {
    pub job: Job,
    /// Results from before an account change are discarded.
    epoch: u64,
    round: u64,
}

pub enum Outcome {
    Section(SectionFetch),
    Checks(ChecksFetch),
    Membership(MembershipFetch),
}

/// The organization membership check, asked once per account.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MembershipCheck {
    Due,
    Asked,
    Answered(Membership),
}

#[derive(Debug, Clone)]
pub struct SectionView {
    pub name: &'static str,
    pub items: Vec<Item>,
    /// The section has loaded at least once, so empty `items` means "none".
    pub loaded: bool,
    /// The latest request failed; `items` are from `fetched_at`.
    pub error: Option<Error>,
    pub warnings: Vec<Error>,
    pub total: u64,
    pub truncated: bool,
    /// Results GitHub returned, before decoding losses and deduplication.
    pub returned: usize,
    /// The page size last fetched successfully, which refreshes keep.
    pub size: u32,
    pub fetched_at: Option<Instant>,
    pub busy: bool,
    /// "Load more" was asked for and hasn't finished; a refresh in flight
    /// runs first.
    pub expanding: bool,
    /// The round each item's data came from, by URL: its section's fetch,
    /// or the newer copy `Inbox::place_rows` put in its place.
    rounds: HashMap<String, u64>,
}

impl SectionView {
    fn new(name: &'static str) -> Self {
        Self {
            name,
            items: Vec::new(),
            loaded: false,
            error: None,
            warnings: Vec::new(),
            total: 0,
            truncated: false,
            returned: 0,
            size: PAGE_STEP,
            fetched_at: None,
            busy: false,
            expanding: false,
            rounds: HashMap::new(),
        }
    }

    pub fn can_load_more(&self) -> bool {
        self.truncated && self.size < PAGE_MAX
    }

    /// Records the outcome; returns whether new items arrived.
    fn apply(&mut self, size: u32, round: u64, fetch: SectionFetch, now: Instant) -> bool {
        self.busy = false;
        self.warnings = fetch.warnings;
        let page = match fetch.page {
            Ok(page) => page,
            Err(err) => {
                self.error = Some(err);
                return false;
            }
        };
        self.items = page.items;
        self.total = page.total;
        self.truncated = page.truncated;
        self.returned = page.returned;
        self.size = size;
        self.loaded = true;
        self.error = None;
        self.fetched_at = Some(now);
        self.rounds = self.items.iter().map(|i| (i.url.clone(), round)).collect();
        true
    }
}

/// A section fetch waiting for a free slot.
#[derive(Debug, Clone, Copy)]
struct Queued {
    index: usize,
    size: u32,
    direct_only: bool,
    /// The round its result will count as.
    round: u64,
}

/// How a PR's check dot should read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckView {
    /// Nothing known for the current head commit yet.
    Loading,
    /// `stale` when the latest lookup for this head failed. A pending
    /// recheck changes nothing, so a refresh doesn't flash every dot.
    Known {
        checks: Option<Checks>,
        stale: bool,
    },
    Failed(Error),
}

pub struct Inbox {
    pub identity: Option<Identity>,
    /// The review entry belongs to the selected `review_direct_only` mode.
    pub sections: Vec<SectionView>,
    pub owner_filter: OwnerFilter,
    review_direct_only: bool,
    /// The review section in the mode not selected, so neither mode's rows,
    /// counts or errors ever show under the other.
    review_parked: SectionView,
    /// The section each item's row is in, by URL (`place_rows`).
    placed: HashMap<String, usize>,
    membership: MembershipCheck,
    /// Rows from both personal and organization repos have loaded.
    mixed_owners: bool,
    epoch: u64,
    round: u64,
    running: usize,
    sections_queued: VecDeque<Queued>,
    checks_queued: VecDeque<String>,
    /// PR ids queued or running, with the head commit each was asked for.
    checks_pending: HashMap<String, String>,
    /// Each displayed PR's latest head commit from any section.
    heads: HashMap<String, String>,
    checks: HashMap<String, CheckState>,
    check_errors: HashMap<String, Error>,
}

impl Default for Inbox {
    fn default() -> Self {
        Self {
            identity: None,
            sections: SECTIONS.iter().map(|s| SectionView::new(s.name)).collect(),
            owner_filter: OwnerFilter::All,
            review_direct_only: false,
            review_parked: SectionView::new(SECTIONS[REVIEW_SECTION].name),
            placed: HashMap::new(),
            membership: MembershipCheck::Due,
            mixed_owners: false,
            epoch: 0,
            round: 0,
            running: 0,
            sections_queued: VecDeque::new(),
            checks_queued: VecDeque::new(),
            checks_pending: HashMap::new(),
            heads: HashMap::new(),
            checks: HashMap::new(),
            check_errors: HashMap::new(),
        }
    }
}

impl Inbox {
    /// Queues every idle section at its current size. Returns how many.
    pub fn refresh(&mut self) -> usize {
        self.round += 1;
        let mut queued = 0;
        for index in 0..self.sections.len() {
            if !self.sections[index].busy {
                self.queue_section(index, self.sections[index].size);
                queued += 1;
            }
        }
        queued
    }

    /// Queues a selected section at the current round.
    fn queue_section(&mut self, index: usize, size: u32) {
        self.sections[index].busy = true;
        self.sections_queued.push_back(Queued {
            index,
            size,
            direct_only: index == REVIEW_SECTION && self.review_direct_only,
            round: self.round,
        });
    }

    /// Queues the section again, one step larger. Its rows and size stay
    /// until the larger page arrives. It gets a round of its own, so its
    /// copies beat older duplicates in earlier sections.
    pub fn load_more(&mut self, index: usize) -> bool {
        let section = &mut self.sections[index];
        if section.expanding || !section.can_load_more() {
            return false;
        }
        section.expanding = true;
        if !section.busy {
            self.expand(index);
        }
        true
    }

    fn expand(&mut self, index: usize) {
        let size = (self.sections[index].size + PAGE_STEP).min(PAGE_MAX);
        self.round += 1;
        self.queue_section(index, size);
    }

    pub fn review_direct_only(&self) -> bool {
        self.review_direct_only
    }

    /// Teams exist only in organizations, so without a membership both
    /// review searches match the same requests.
    pub fn show_direct_only(&self) -> bool {
        matches!(
            self.membership,
            MembershipCheck::Answered(Membership::Member | Membership::Unknown)
        )
    }

    pub fn show_owner_tabs(&self) -> bool {
        self.mixed_owners
    }

    /// Shows the chosen mode's own review results and refetches them.
    /// Returns whether anything changed.
    pub fn set_review_direct_only(&mut self, direct_only: bool) -> bool {
        if self.review_direct_only == direct_only {
            return false;
        }
        let left = self.review_direct_only;
        self.review_direct_only = direct_only;
        std::mem::swap(&mut self.sections[REVIEW_SECTION], &mut self.review_parked);
        let queued = self.sections_queued.len();
        self.sections_queued
            .retain(|q| !(q.index == REVIEW_SECTION && q.direct_only == left));
        if self.sections_queued.len() < queued {
            self.review_parked.busy = false;
        }
        self.place_rows(None);
        self.track_checks(REVIEW_SECTION);
        if !self.sections[REVIEW_SECTION].busy {
            self.round += 1;
            self.queue_section(REVIEW_SECTION, self.sections[REVIEW_SECTION].size);
        }
        true
    }

    /// The next job to start, if a slot is free. Sections go first, so rows
    /// never wait behind check lookups.
    pub fn next_job(&mut self) -> Option<Ticket> {
        if self.running >= CONCURRENCY {
            return None;
        }
        let (job, round) = if let Some(q) = self.sections_queued.pop_front() {
            (
                Job::Section {
                    index: q.index,
                    size: q.size,
                    direct_only: q.direct_only,
                },
                q.round,
            )
        } else if self.membership == MembershipCheck::Due {
            self.membership = MembershipCheck::Asked;
            (Job::Membership, self.round)
        } else if !self.checks_queued.is_empty() {
            let n = self.checks_queued.len().min(CHECK_BATCH);
            let ids = self.checks_queued.drain(..n).collect();
            (Job::Checks { ids }, self.round)
        } else {
            return None;
        };
        self.running += 1;
        Some(Ticket {
            job,
            epoch: self.epoch,
            round,
        })
    }

    pub fn any_busy(&self) -> bool {
        self.running > 0
            || !self.sections_queued.is_empty()
            || !self.checks_queued.is_empty()
            || self.membership == MembershipCheck::Due
    }

    /// Applies a finished job. Returns true when it revealed a different
    /// account: everything was cleared and a refresh should follow.
    pub fn finish(&mut self, ticket: Ticket, outcome: Outcome, now: Instant) -> bool {
        self.running = self.running.saturating_sub(1);
        if ticket.epoch != self.epoch {
            return false;
        }
        let identity = match &outcome {
            Outcome::Section(fetch) => fetch.identity.as_ref(),
            Outcome::Checks(fetch) => fetch.identity.as_ref(),
            Outcome::Membership(fetch) => fetch.identity.as_ref(),
        };
        let switched = match (identity, &self.identity) {
            (Some(new), Some(old)) => new != old,
            _ => false,
        };
        if switched {
            self.reset();
        }
        if let Some(identity) = identity {
            self.identity = Some(identity.clone());
        }
        match (ticket.job, outcome) {
            (
                Job::Section {
                    index,
                    size,
                    direct_only,
                },
                Outcome::Section(fetch),
            ) => {
                // After a switch the section was reset to idle; this result
                // still belongs to the new account.
                let selected = index != REVIEW_SECTION || direct_only == self.review_direct_only;
                let section = if selected {
                    &mut self.sections[index]
                } else {
                    &mut self.review_parked
                };
                let expansion = size > section.size;
                let loaded = section.apply(size, ticket.round, fetch, now);
                if section.expanding && (expansion || !section.can_load_more()) {
                    section.expanding = false;
                }
                if selected {
                    self.place_rows(loaded.then_some(index));
                    if loaded {
                        self.track_checks(index);
                        self.note_owners();
                    }
                    // A "Load more" that arrived during a refresh.
                    if self.sections[index].expanding && !self.sections[index].busy {
                        self.expand(index);
                    }
                }
            }
            (Job::Membership, Outcome::Membership(fetch)) => {
                self.membership = MembershipCheck::Answered(fetch.membership);
            }
            (Job::Checks { .. }, Outcome::Checks(fetch)) => self.apply_checks(fetch),
            _ => {}
        }
        switched
    }

    fn reset(&mut self) {
        // Filters start over too: the new account's controls may be hidden.
        *self = Self {
            epoch: self.epoch + 1,
            round: self.round,
            running: self.running,
            ..Self::default()
        };
    }

    /// Unfiltered, so choosing a tab can never hide the tabs.
    fn note_owners(&mut self) {
        if self.mixed_owners {
            return;
        }
        let kinds: HashSet<OwnerKind> = self
            .sections
            .iter()
            .flat_map(|s| &s.items)
            .map(|i| i.repository.owner_kind())
            .collect();
        self.mixed_owners =
            kinds.contains(&OwnerKind::Personal) && kinds.contains(&OwnerKind::Organization);
    }

    /// Expects each PR's head from the copy that is displayed, looks up
    /// checks for a section's PRs, and forgets PRs no longer displayed.
    fn track_checks(&mut self, index: usize) {
        let mut heads = HashMap::new();
        for (section, shown) in self.sections.iter().zip(self.deduplicated()) {
            for i in shown {
                let item = &section.items[i];
                if let Some(head) = &item.head {
                    heads.insert(item.id.clone(), head.clone());
                }
            }
        }
        // An error describes the head it was asked for.
        self.check_errors
            .retain(|id, _| heads.get(id) == self.heads.get(id));
        let wanted: Vec<(String, String)> = self.sections[index]
            .items
            .iter()
            .filter_map(|i| Some((i.id.clone(), heads.get(&i.id)?.clone())))
            .collect();
        self.checks.retain(|id, _| heads.contains_key(id));
        self.heads = heads;
        for (id, head) in wanted {
            // A lookup already running for another head is followed up
            // when it finishes.
            if !self.checks_pending.contains_key(&id) {
                self.queue_check(id, head);
            }
        }
    }

    /// Shown state and errors stay until the answer replaces them.
    fn queue_check(&mut self, id: String, head: String) {
        self.checks_pending.insert(id.clone(), head);
        self.checks_queued.push_back(id);
    }

    fn apply_checks(&mut self, fetch: ChecksFetch) {
        for (id, result) in fetch.results {
            // Not pending: the PR left every section, or the account changed.
            let Some(asked) = self.checks_pending.remove(&id) else {
                continue;
            };
            let Some(wanted) = self.heads.get(&id).cloned() else {
                continue;
            };
            if asked != wanted {
                // A section showed a newer head while this lookup ran.
                if let Ok(state) = result {
                    self.checks.insert(id.clone(), state);
                }
                self.check_errors.remove(&id);
                self.queue_check(id, wanted);
                continue;
            }
            match result {
                Ok(state) if state.head != wanted => {
                    self.check_errors.insert(id.clone(), Error::OtherCommit);
                    self.checks.insert(id, state);
                }
                Ok(state) => {
                    self.check_errors.remove(&id);
                    self.checks.insert(id, state);
                }
                Err(err) => {
                    self.check_errors.insert(id, err);
                }
            }
        }
    }

    /// `None` for issues.
    pub fn check(&self, item: &Item) -> Option<CheckView> {
        let head = item.head.as_deref()?;
        let error = self.check_errors.get(&item.id);
        Some(match self.checks.get(&item.id) {
            Some(state) if state.head == head => CheckView::Known {
                checks: state.checks,
                stale: error.is_some(),
            },
            _ => match error {
                Some(err) => CheckView::Failed(err.clone()),
                None => CheckView::Loading,
            },
        })
    }

    /// Lookups that failed for the rows on screen: how many, and the first error.
    pub fn check_failures(&self) -> Option<(usize, &Error)> {
        let visible = self.visible();
        let mut failed = self
            .sections
            .iter()
            .zip(&visible)
            .flat_map(|(s, shown)| shown.iter().map(move |&i| &s.items[i]))
            .filter_map(|item| self.check_errors.get(&item.id));
        let first = failed.next()?;
        Some((1 + failed.count(), first))
    }

    /// The error every section's latest attempt failed with, when they all
    /// share one: it is shown once instead of under each section.
    pub fn common_error(&self) -> Option<&Error> {
        let first = self.sections.first()?.error.as_ref()?;
        self.sections
            .iter()
            .all(|s| s.error.as_ref() == Some(first))
            .then_some(first)
    }

    pub fn any_loaded(&self) -> bool {
        self.sections.iter().any(|s| s.loaded)
    }

    /// When data last arrived for any section.
    pub fn updated(&self) -> Option<Instant> {
        self.sections.iter().filter_map(|s| s.fetched_at).max()
    }

    /// The indexes of each section's items to show: `deduplicated`, less
    /// what the owner tab hides.
    pub fn visible(&self) -> Vec<Vec<usize>> {
        self.sections
            .iter()
            .zip(self.deduplicated())
            .map(|(section, shown)| {
                shown
                    .into_iter()
                    .filter(|&i| self.owner_filter.matches(&section.items[i]))
                    .collect()
            })
            .collect()
    }

    /// Keeps each row in its section until a successful fetch drops it
    /// there, or an earlier section's successful fetch (`answered`) claims
    /// it; a new item goes to the first section with it. Failed and pending
    /// fetches never move a row. A row shows the newest copy of its item, but
    /// keeps its own section's review route.
    fn place_rows(&mut self, answered: Option<usize>) {
        let mut holders: HashMap<String, Vec<usize>> = HashMap::new();
        for (s, section) in self.sections.iter().enumerate() {
            for item in &section.items {
                let sections = holders.entry(item.url.clone()).or_default();
                if sections.last() != Some(&s) {
                    sections.push(s);
                }
            }
        }
        let mut placed = HashMap::with_capacity(holders.len());
        let mut reranked = HashSet::new();
        for (url, sections) in holders {
            let held = self
                .placed
                .get(&url)
                .copied()
                .filter(|p| sections.contains(p));
            let place = match (held, answered) {
                (Some(held), Some(a)) if a < held && sections.contains(&a) => a,
                (Some(held), _) => held,
                (None, _) => sections[0],
            };
            let round = |s: usize| self.sections[s].rounds.get(&url).copied().unwrap_or(0);
            let newest =
                sections.iter().copied().fold(
                    place,
                    |best, s| if round(s) > round(best) { s } else { best },
                );
            if newest != place {
                let fresh_round = round(newest);
                let fresh = self.sections[newest]
                    .items
                    .iter()
                    .find(|i| i.url == url)
                    .cloned();
                let slot = self.sections[place].items.iter_mut().find(|i| i.url == url);
                if let (Some(fresh), Some(slot)) = (fresh, slot) {
                    let route = slot.review_route.take();
                    *slot = Item {
                        review_route: route,
                        ..fresh
                    };
                    self.sections[place].rounds.insert(url.clone(), fresh_round);
                    reranked.insert(place);
                }
            }
            placed.insert(url, place);
        }
        for s in reranked {
            crate::github::rank(&mut self.sections[s].items);
        }
        self.placed = placed;
    }

    /// Each item once, in the section `place_rows` chose.
    fn deduplicated(&self) -> Vec<Vec<usize>> {
        let mut shown = HashSet::new();
        self.sections
            .iter()
            .enumerate()
            .map(|(s, section)| {
                section
                    .items
                    .iter()
                    .enumerate()
                    .filter(|(_, item)| self.placed.get(&item.url) == Some(&s))
                    .filter(|(_, item)| shown.insert(item.url.as_str()))
                    .map(|(index, _)| index)
                    .collect()
            })
            .collect()
    }
}

/// "just now", "4m ago", "2h ago".
pub fn ago(then: Instant, now: Instant) -> String {
    let secs = now.saturating_duration_since(then).as_secs();
    match secs {
        0..60 => "just now".to_owned(),
        60..3600 => format!("{}m ago", secs / 60),
        _ => format!("{}h ago", secs / 3600),
    }
}

#[cfg(test)]
mod tests;
