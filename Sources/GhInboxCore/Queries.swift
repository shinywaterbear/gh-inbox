/// The GraphQL each request is built from (`Gh`). Check states come
/// separately: they roughly doubled a page's latency.
enum Queries {
  /// The fields fetched for every section's search.
  static let items = """
    fragment items on SearchResultItemConnection {
      issueCount
      pageInfo { hasNextPage }
      nodes {
        __typename
        ... on PullRequest {
          id number title url updatedAt isDraft reviewDecision headRefOid
          author { login }
          repository { name nameWithOwner owner { __typename } }
          # reviewDecision is null unless a branch rule requires reviews.
          latestOpinionatedReviews(first: 50) { pageInfo { hasNextPage } nodes { state } }
        }
        ... on Issue {
          id number title url updatedAt
          author { login }
          repository { name nameWithOwner owner { __typename } }
        }
      }
    }

    """

  /// Added to the review section's search only, to tell a direct request
  /// from a team's. pageInfo matters: a cut-off list may hide the viewer.
  static let requests = """
    fragment requests on PullRequest {
      reviewRequests(first: 25) {
        pageInfo { hasNextPage }
        nodes { requestedReviewer { __typename ... on Actor { login } ... on Team { name } } }
      }
    }

    """

  /// A PR's check state looked up by id, plus the checks its base branch
  /// requires: GitHub's rollup omits a required check that never reported.
  static let checks = """
    fragment checks on PullRequest {
      id headRefOid
      commits(last: 1) { nodes { commit { ...rollup } } }
      # The test merge commit: when it has a status, it is what must pass.
      potentialMergeCommit { ...rollup }
      baseRef {
        branchProtectionRule { requiredStatusCheckContexts }
        rules(first: 100) {
          nodes {
            parameters {
              __typename
              ... on RequiredStatusChecksParameters { requiredStatusChecks { context } }
            }
          }
        }
      }
    }

    fragment rollup on Commit {
      statusCheckRollup {
        state
        contexts(first: 100) {
          totalCount
          nodes {
            __typename
            ... on CheckRun { name }
            ... on StatusContext { context }
          }
        }
      }
    }

    """

  /// Identity plus whether the viewer belongs to any organization. A second
  /// `viewer` alias keeps the identity decodable on its own.
  static let membership = """
    query {
      viewer { login url }
      memberships: viewer { organizations(first: 1) { totalCount } }
    }

    """
}
