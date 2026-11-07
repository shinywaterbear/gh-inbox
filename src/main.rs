mod github;
mod inbox;

use std::collections::HashSet;
use std::time::{Duration, Instant};

use gpui::{
    App, Application, Bounds, ClipboardItem, Context, FocusHandle, KeyBinding, Pixels,
    SharedString, Subscription, Task, Window, WindowBounds, WindowOptions, actions, div,
    prelude::*, px, rgb, size, uniform_list,
};

use github::{Checks, Error, Item, Review, ReviewRoute};
use inbox::{CheckView, Inbox, Job, Outcome, OwnerFilter, Trigger};

actions!(gh_inbox, [Quit, Refresh]);

const BG: u32 = 0x1e1f22;
const ROW_HOVER: u32 = 0x2b2d31;
const BORDER: u32 = 0x3a3c42;
const TEXT: u32 = 0xdcddde;
const MUTED: u32 = 0x8e9297;
const ERROR: u32 = 0xf85149;
const WARNING: u32 = 0xd29922;
const PR: u32 = 0x3fb950;
const ISSUE: u32 = 0x58a6ff;
const DRAFT: u32 = 0x6e7681;
const CHANGES: u32 = 0xdb6d28;
const PENDING: u32 = 0xd29922;

/// uniform_list measures one row and positions the rest from it, so every row
/// kind renders at exactly this height.
const ROW_HEIGHT: Pixels = px(36.);
/// How often the scheduler checks whether a refresh is due, and ages re-render.
const TICK: Duration = Duration::from_secs(10);

const OWNER_TABS: [(OwnerFilter, &str); 3] = [
    (OwnerFilter::All, "All"),
    (OwnerFilter::Personal, "Personal"),
    (OwnerFilter::Organization, "Org"),
];

/// A list row, pointing into `Inbox` rather than copying items.
enum Row {
    Heading {
        section: usize,
        first: bool,
        /// Items this section actually displays.
        shown: usize,
    },
    Notice {
        text: String,
        color: u32,
        url: Option<String>,
    },
    Item {
        section: usize,
        index: usize,
    },
    LoadMore {
        section: usize,
    },
}

struct OpenWork {
    inbox: Inbox,
    rows: Vec<Row>,
    multi_owner: bool,
    focused: bool,
    last_attempt: Option<Instant>,
    focus_handle: FocusHandle,
    _activation: Subscription,
    _scheduler: Task<()>,
}

impl OpenWork {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let activation = cx.observe_window_activation(window, |view, window, cx| {
            view.focused = window.is_window_active();
            view.refresh_if_due(Trigger::Focus, cx);
        });
        let scheduler = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(TICK).await;
                let alive = this.update(cx, |view, cx| {
                    view.refresh_if_due(Trigger::Tick, cx);
                    // Ages like "updated 3m ago" move without new data.
                    view.rebuild_rows();
                    cx.notify();
                });
                if alive.is_err() {
                    break;
                }
            }
        });
        let mut view = Self {
            inbox: Inbox::default(),
            rows: Vec::new(),
            multi_owner: false,
            focused: window.is_window_active(),
            last_attempt: None,
            focus_handle: cx.focus_handle(),
            _activation: activation,
            _scheduler: scheduler,
        };
        view.refresh(cx);
        view
    }

    fn refresh_if_due(&mut self, trigger: Trigger, cx: &mut Context<Self>) {
        let since = self.last_attempt.map(|t| t.elapsed());
        if inbox::due(trigger, self.focused, since) {
            self.refresh(cx);
        }
    }

    /// Keeps the current rows on screen until the new ones arrive.
    fn refresh(&mut self, cx: &mut Context<Self>) {
        if self.inbox.refresh() > 0 {
            self.last_attempt = Some(Instant::now());
        }
        self.pump(cx);
    }

    fn load_more(&mut self, section: usize, cx: &mut Context<Self>) {
        if self.inbox.load_more(section) {
            self.pump(cx);
        }
    }

    /// Starts queued jobs while slots are free; each finished job applies its
    /// result, renders it at once and pumps again.
    fn pump(&mut self, cx: &mut Context<Self>) {
        while let Some(ticket) = self.inbox.next_job() {
            let job = ticket.job.clone();
            cx.spawn(async move |this, cx| {
                let outcome = cx
                    .background_executor()
                    .spawn(async move {
                        let gh = github::Gh::resolved();
                        match job {
                            Job::Section {
                                index,
                                size,
                                direct_only,
                            } => Outcome::Section(gh.section(index, size, direct_only)),
                            Job::Checks { ids } => Outcome::Checks(gh.checks(&ids)),
                            Job::Membership => Outcome::Membership(gh.membership()),
                        }
                    })
                    .await;
                this.update(cx, |view, cx| {
                    if view.inbox.finish(ticket, outcome, Instant::now()) {
                        view.inbox.refresh();
                    }
                    view.pump(cx);
                    view.rebuild_rows();
                })
            })
            .detach();
        }
        self.rebuild_rows();
        cx.notify();
    }

    fn rebuild_rows(&mut self) {
        let now = Instant::now();
        let mut rows = Vec::new();
        let mut owners = HashSet::new();
        let visible = self.inbox.visible();
        let common = self.inbox.common_error().is_some();
        for (s, (section, shown)) in self.inbox.sections.iter().zip(&visible).enumerate() {
            rows.push(Row::Heading {
                section: s,
                first: rows.is_empty(),
                shown: shown.len(),
            });
            if let Some(err) = section.error.as_ref().filter(|_| !common) {
                let text = match section.fetched_at {
                    Some(t) => format!(
                        "{} Showing results from {}.",
                        describe(err),
                        inbox::ago(t, now)
                    ),
                    None => describe(err),
                };
                rows.push(Row::Notice {
                    text,
                    color: ERROR,
                    url: None,
                });
            }
            for warning in &section.warnings {
                rows.push(Row::Notice {
                    text: describe(warning),
                    color: WARNING,
                    url: None,
                });
            }
            for &index in shown {
                owners.insert(section.items[index].owner());
                rows.push(Row::Item { section: s, index });
            }
            if section.can_load_more() {
                rows.push(Row::LoadMore { section: s });
            }
            if section.truncated {
                let host = self
                    .inbox
                    .identity
                    .as_ref()
                    .map_or("github.com", |i| &i.host);
                // The owner tabs filter only what's already fetched.
                let before_filter = if self.inbox.owner_filter == OwnerFilter::All {
                    ""
                } else {
                    " before the Personal/Org filter"
                };
                rows.push(Row::Notice {
                    text: format!(
                        "Fetched the newest {} of {} matches{before_filter}; {} shown here. Open the full search on GitHub.",
                        section.returned,
                        section.total,
                        shown.len()
                    ),
                    color: WARNING,
                    url: Some(github::search_url(
                        s,
                        host,
                        self.inbox.review_direct_only(),
                    )),
                });
            }
        }
        self.multi_owner = owners.len() > 1;
        self.rows = rows;
    }

    fn header(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let (prs, drafts, issues) = self
            .rows
            .iter()
            .filter_map(|row| match row {
                Row::Item { section, index } => Some(&self.inbox.sections[*section].items[*index]),
                _ => None,
            })
            .fold((0, 0, 0), |(p, d, i), item| match item {
                item if item.is_draft => (p, d + 1, i),
                item if item.is_pull_request => (p + 1, d, i),
                _ => (p, d, i + 1),
            });
        let busy = self.inbox.any_busy();
        let mut summary = Vec::new();
        if !self.inbox.any_loaded() {
            summary.push(if busy { "Loading…" } else { "Unavailable" }.to_owned());
        } else {
            summary.push(format!("{prs} PRs"));
            if drafts > 0 {
                summary.push(format!("{drafts} drafts"));
            }
            summary.push(format!("{issues} issues"));
            if busy {
                summary.push("refreshing…".to_owned());
            } else if let Some(t) = self.inbox.updated() {
                summary.push(format!("updated {}", inbox::ago(t, Instant::now())));
            }
        }
        let title = match &self.inbox.identity {
            Some(id) if id.host == "github.com" => format!("Open for {}", id.login),
            Some(id) => format!("Open for {} on {}", id.login, id.host),
            None => "Open work".to_owned(),
        };
        div()
            .flex()
            .items_center()
            .justify_between()
            .px_4()
            .py_3()
            .border_b_1()
            .border_color(rgb(BORDER))
            .child(
                div()
                    .flex()
                    .gap_3()
                    .items_baseline()
                    .min_w_0()
                    .child(div().text_lg().child(title))
                    .child(
                        div()
                            .text_sm()
                            .text_color(rgb(MUTED))
                            .truncate()
                            .child(summary.join(" · ")),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_none()
                    .items_center()
                    .gap_2()
                    .child(self.owner_tabs(cx))
                    .child(self.direct_only_toggle(cx))
                    .child(
                        div()
                            .id("refresh")
                            .px_3()
                            .py_1()
                            .rounded_md()
                            .border_1()
                            .border_color(rgb(BORDER))
                            .cursor_pointer()
                            .hover(|s| s.bg(rgb(ROW_HOVER)))
                            .on_click(cx.listener(|view, _, _, cx| view.refresh(cx)))
                            .child(refresh_label(busy)),
                    ),
            )
    }

    /// Hidden controls keep their slot so nothing beside them moves, and
    /// an invisible element takes no clicks.
    fn owner_tabs(&self, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .gap_1()
            .when(!self.inbox.show_owner_tabs(), |d| d.invisible())
            .children(OWNER_TABS.into_iter().map(|(filter, label)| {
                let active = self.inbox.owner_filter == filter;
                div()
                    .id(SharedString::from(format!("owner-{label}")))
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .text_sm()
                    .cursor_pointer()
                    .when(active, |d| d.bg(rgb(ROW_HOVER)).text_color(rgb(TEXT)))
                    .when(!active, |d| {
                        d.text_color(rgb(MUTED)).hover(|s| s.bg(rgb(ROW_HOVER)))
                    })
                    .on_click(cx.listener(move |view, _, _, cx| {
                        view.inbox.owner_filter = filter;
                        view.rebuild_rows();
                        cx.notify();
                    }))
                    .child(label)
            }))
    }

    fn direct_only_toggle(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let active = self.inbox.review_direct_only();
        div()
            .id("direct-only")
            .when(!self.inbox.show_direct_only(), |d| d.invisible())
            .flex()
            .items_center()
            .gap_2()
            .px_2()
            .py_1()
            .rounded_md()
            .cursor_pointer()
            .hover(|s| s.bg(rgb(ROW_HOVER)))
            .on_click(cx.listener(|view, _, _, cx| {
                let next = !view.inbox.review_direct_only();
                if view.inbox.set_review_direct_only(next) {
                    view.pump(cx);
                }
                cx.notify();
            }))
            .child(
                div()
                    .size(px(13.))
                    .flex_none()
                    .rounded(px(3.))
                    .border_1()
                    .border_color(rgb(if active { ISSUE } else { BORDER }))
                    .when(active, |d| d.bg(rgb(ISSUE))),
            )
            .child(div().text_sm().text_color(rgb(TEXT)).child("Direct only"))
    }

    /// Problems that aren't tied to a section, shown in full above the list.
    fn banners(&self) -> impl IntoElement {
        let now = Instant::now();
        let refresh = self.inbox.common_error().map(|err| {
            let when = self
                .inbox
                .updated()
                .map(|t| format!(" Showing results from {}.", inbox::ago(t, now)))
                .unwrap_or_default();
            banner(format!("Couldn't refresh: {}{when}", describe(err)), ERROR)
        });
        let checks = self.inbox.check_failures().map(|(n, err)| {
            banner(
                format!("Couldn't load checks for {n} PR(s): {}", describe(err)),
                WARNING,
            )
        });
        div().flex().flex_col().children(refresh).children(checks)
    }

    fn list(&self, cx: &mut Context<Self>) -> impl IntoElement {
        uniform_list(
            "rows",
            self.rows.len(),
            cx.processor(|view, range: std::ops::Range<usize>, _window, cx| {
                view.rows[range]
                    .iter()
                    .map(|row| view.render_row(row, cx))
                    .collect()
            }),
        )
        .flex_grow()
    }

    fn render_row(&self, row: &Row, cx: &mut Context<Self>) -> gpui::AnyElement {
        let base = div()
            .h(ROW_HEIGHT)
            .w_full()
            .flex()
            .items_center()
            .gap_3()
            .px_4()
            .text_sm();
        match row {
            // A rule above every section but the first, which sits under the header's.
            Row::Heading {
                section,
                first,
                shown,
            } => {
                let index = *section;
                let section = &self.inbox.sections[index];
                let empty = section.loaded && *shown == 0;
                base.when(!first, |d| d.border_t_1())
                    .border_color(rgb(BORDER))
                    // An empty section stays as a dimmed heading: "nothing
                    // waiting" is worth seeing, a row saying so is not.
                    .child(
                        div()
                            .when(empty, |d| d.text_color(rgb(MUTED)))
                            .child(section.name),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(rgb(MUTED))
                            // Never loaded is unknown, not zero.
                            .child(if section.loaded {
                                shown.to_string()
                            } else {
                                "—".to_owned()
                            }),
                    )
                    .into_any_element()
            }
            // Notices truncate to one row, so the full text is a hover away,
            // and a click opens their link or copies them.
            Row::Notice { text, color, url } => {
                let full = SharedString::from(text.clone());
                let tip = match url {
                    Some(_) => full.clone(),
                    None => format!("{full}\n\nClick to copy.").into(),
                };
                let copy = full.clone();
                let url = url.clone();
                base.id(SharedString::from(format!("notice-{text}")))
                    .text_color(rgb(*color))
                    .cursor_pointer()
                    .hover(|s| s.bg(rgb(ROW_HOVER)))
                    .tooltip(move |_, cx| cx.new(|_| Tooltip(tip.clone())).into())
                    .on_click(move |_, _, cx| match &url {
                        Some(url) => cx.open_url(url),
                        None => cx.write_to_clipboard(ClipboardItem::new_string(copy.to_string())),
                    })
                    .child(div().min_w_0().truncate().child(full))
                    .into_any_element()
            }
            Row::Item { section, index } => {
                let item = &self.inbox.sections[*section].items[*index];
                item_row(base, item, self.inbox.check(item), self.multi_owner).into_any_element()
            }
            Row::LoadMore { section } => {
                let index = *section;
                let busy = self.inbox.sections[index].expanding;
                base.id(("load-more", index))
                    .text_color(rgb(if busy { MUTED } else { ISSUE }))
                    .when(!busy, |d| {
                        d.cursor_pointer()
                            .hover(|s| s.bg(rgb(ROW_HOVER)))
                            .on_click(cx.listener(move |view, _, _, cx| view.load_more(index, cx)))
                    })
                    .child(if busy {
                        "Loading…".to_owned()
                    } else {
                        format!("Load {} more", inbox::PAGE_STEP)
                    })
                    .into_any_element()
            }
        }
    }
}

struct Tooltip(SharedString);

impl Render for Tooltip {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .max_w(px(520.))
            .px_3()
            .py_2()
            .rounded_md()
            .border_1()
            .border_color(rgb(BORDER))
            .bg(rgb(ROW_HOVER))
            .text_sm()
            .text_color(rgb(TEXT))
            .child(self.0.clone())
    }
}

fn describe(err: &Error) -> String {
    err.describe()
}

fn banner(text: String, color: u32) -> impl IntoElement {
    div()
        .px_4()
        .py_2()
        .border_b_1()
        .border_color(rgb(BORDER))
        .text_sm()
        .text_color(rgb(color))
        .child(text)
}

fn item_row(
    base: gpui::Div,
    item: &Item,
    check: Option<CheckView>,
    multi_owner: bool,
) -> impl IntoElement + use<> {
    let (kind, color) = match (item.is_pull_request, item.is_draft, item.review) {
        (false, _, _) => ("Issue", ISSUE),
        (true, true, _) => ("Draft", DRAFT),
        (true, false, Some(Review::Approved)) => ("Approved", PR),
        (true, false, Some(Review::ChangesRequested)) => ("Changes", CHANGES),
        (true, false, _) => ("PR", PR),
    };
    let color_of = |checks: Checks| match checks {
        Checks::Passing => PR,
        Checks::Failing => ERROR,
        Checks::Pending => PENDING,
    };
    // Filled: known for the head commit (dimmed while being rechecked).
    // Ring: still loading (muted) or the lookup failed (warning).
    let (fill, ring, dim) = match check {
        None | Some(CheckView::Known { checks: None, .. }) => (None, None, false),
        Some(CheckView::Known {
            checks: Some(c),
            stale,
        }) => (Some(color_of(c)), None, stale),
        Some(CheckView::Loading) => (None, Some(MUTED), false),
        Some(CheckView::Failed(_)) => (None, Some(WARNING), false),
    };
    let title_color = if item.is_draft { MUTED } else { TEXT };
    let repo = if multi_owner {
        &item.repository.name_with_owner
    } else {
        &item.repository.name
    };
    let url = item.url.clone();
    base
        // Keyed by URL so hover state stays with the item when rows shift.
        .id(SharedString::from(item.url.clone()))
        .cursor_pointer()
        .hover(|s| s.bg(rgb(ROW_HOVER)))
        .on_click(move |_, _, cx| cx.open_url(&url))
        .child(
            div()
                .size(px(8.))
                .flex_none()
                .rounded_full()
                .when_some(fill, |d, color| d.bg(rgb(color)))
                .when_some(ring, |d, color| d.border_1().border_color(rgb(color)))
                .when(dim, |d| d.opacity(0.45)),
        )
        .child(
            div()
                .w(px(60.))
                .flex_none()
                .text_xs()
                .text_color(rgb(color))
                .child(kind),
        )
        .child(
            div()
                .w(px(if multi_owner { 240. } else { 170. }))
                .flex_none()
                .text_color(rgb(MUTED))
                .truncate()
                .child(format!("{repo}#{}", item.number)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .items_baseline()
                .gap_2()
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_base()
                        .text_color(rgb(title_color))
                        .child(item.title.clone()),
                )
                .children(route_label(item.review_route.as_ref()).map(|label| {
                    div()
                        .flex_none()
                        .text_xs()
                        .text_color(rgb(MUTED))
                        .child(label)
                })),
        )
        .child(
            div()
                .w(px(110.))
                .flex_none()
                .text_xs()
                .text_color(rgb(MUTED))
                .truncate()
                .child(item.author.clone()),
        )
        .child(
            div()
                .w(px(72.))
                .flex_none()
                .text_xs()
                .text_color(rgb(MUTED))
                .child(item.updated_at.get(..10).unwrap_or_default().to_owned()),
        )
}

/// Always as wide as "Refreshing…", so the controls beside it never shift.
fn refresh_label(busy: bool) -> impl IntoElement {
    div()
        .relative()
        .child(div().invisible().child("Refreshing…"))
        .child(
            div()
                .absolute()
                .inset_0()
                .flex()
                .justify_center()
                .child(if busy { "Refreshing…" } else { "Refresh" }),
        )
}

fn route_label(route: Option<&ReviewRoute>) -> Option<String> {
    match route? {
        ReviewRoute::Direct => None,
        ReviewRoute::Team(team) => Some(format!("via {team}")),
        ReviewRoute::SomeTeam => Some("via a team".to_owned()),
        ReviewRoute::Unknown => Some("request source unknown".to_owned()),
    }
}

fn unavailable(err: &Error) -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .gap_2()
        .p_6()
        .child(
            div()
                .text_lg()
                .text_color(rgb(ERROR))
                .child(err.to_string()),
        )
        .children(
            err.hint()
                .map(|hint| div().text_sm().text_color(rgb(MUTED)).child(hint)),
        )
}

impl Render for OpenWork {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // Sections render as each arrives; one shared failure before any
        // data is shown once, as a panel.
        let body = match self
            .inbox
            .common_error()
            .filter(|_| !self.inbox.any_loaded())
        {
            Some(err) => unavailable(err),
            None => div()
                .flex()
                .flex_col()
                .flex_grow()
                .child(self.banners())
                .child(self.list(cx)),
        };
        div()
            .key_context("OpenWork")
            .track_focus(&self.focus_handle)
            .on_action(cx.listener(|view, _: &Refresh, _, cx| view.refresh(cx)))
            .flex()
            .flex_col()
            .size_full()
            .bg(rgb(BG))
            .text_color(rgb(TEXT))
            .child(self.header(cx))
            .child(body)
    }
}

/// Without a bundle, the Dock shows the generic executable icon.
#[cfg(target_os = "macos")]
fn set_dock_icon() {
    use objc2::{AllocAnyThread, MainThreadMarker};
    use objc2_app_kit::{NSApplication, NSImage};
    use objc2_foundation::NSData;

    const ICON: &[u8] = include_bytes!("../assets/icon.png");
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let data = NSData::with_bytes(ICON);
    let Some(image) = NSImage::initWithData(NSImage::alloc(), &data) else {
        return;
    };
    // SAFETY: on the main thread, with a fully initialised image.
    unsafe { NSApplication::sharedApplication(mtm).setApplicationIconImage(Some(&image)) };
}

fn main() {
    Application::new().run(|cx: &mut App| {
        #[cfg(target_os = "macos")]
        set_dock_icon();
        cx.bind_keys([
            KeyBinding::new("cmd-q", Quit, None),
            KeyBinding::new("cmd-r", Refresh, None),
        ]);
        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();

        let bounds = Bounds::centered(None, size(px(1000.), px(680.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                // Below this the fixed metadata columns squeeze titles to nothing.
                window_min_size: Some(size(px(760.), px(320.))),
                ..Default::default()
            },
            |window, cx| {
                let view = cx.new(|cx| OpenWork::new(window, cx));
                // The view's own handle, tracked by its root, so `cmd-r` reaches
                // its Refresh handler.
                let focus = view.read(cx).focus_handle.clone();
                window.focus(&focus);
                view
            },
        )
        .expect("open window");
        cx.activate(true);
    });
}
