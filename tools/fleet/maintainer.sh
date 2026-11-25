#!/bin/bash
# Maintainer commands for the Mac test fleet (see docs/fleet.md).
#
#   tools/fleet/maintainer.sh labels               create or update the fleet labels
#   tools/fleet/maintainer.sh tasks COMMIT [CHIP…]  open one test-matrix task per chip
#                                                  (default: every chip in fleet.json)
#   tools/fleet/maintainer.sh report               Markdown report of every accepted result
set -euo pipefail
# shellcheck source=tools/fleet/lib.sh
. "$(dirname "$0")/lib.sh"

REPO="${FLEET_REPO:-$(conf .repo)}"
die() {
    printf 'maintainer: %s\n' "$*" >&2
    exit 1
}

cmd_labels() {
    gh label create "$(label task)" -R "$REPO" --force --color 5319e7 --description "Mac test fleet task"
    gh label create "$(label open)" -R "$REPO" --force --color 0e8a16 --description "Fleet task waiting for a worker"
    gh label create "$(label leased)" -R "$REPO" --force --color fbca04 --description "Fleet task leased to a worker"
    gh label create "$(label "done")" -R "$REPO" --force --color 1d76db --description "Fleet task with an accepted result"
    gh label create "$(label passing)" -R "$REPO" --force --color 0e8a16 --description "Fleet result: every test passed"
    gh label create "$(label failing)" -R "$REPO" --force --color d93f0b --description "Fleet result: setup or tests failed"
    gh label create "$(label review)" -R "$REPO" --force --color b60205 --description "Moderation bot flagged text for review"
    gh label create "$(label finding)" -R "$REPO" --force --color 5319e7 --description "Fleet finding: a failure signature or slowdown to fix"
    gh label create "$(label regressed)" -R "$REPO" --force --color b60205 --description "Fleet finding seen again after it was closed"
    local topic
    for topic in $FLEET_TOPICS; do
        gh label create "fleet:topic:$topic" -R "$REPO" --force --color ededed --description "Fleet finding topic: $topic"
    done
    local chip
    for chip in $(conf '.chips[]'); do
        gh label create "$(chip_label "$chip")" -R "$REPO" --force --color c5def5 --description "Fleet task for Apple $chip Macs"
    done
}

cmd_tasks() {
    [ -n "${1:-}" ] || die "usage: maintainer.sh tasks COMMIT [CHIP...]"
    local who commit chip chips
    who=$(gh api user --jq .login)
    is_maintainer "$who" || die "$who is not in tools/fleet/fleet.json maintainers; the queue would ignore these tasks"
    commit=$(gh api "repos/$REPO/commits/$1" --jq .sha) || die "no commit $1 in $REPO"
    shift
    chips=${*:-$(conf '.chips[]')}
    for chip in $chips; do
        is_chip "$chip" || die "unknown chip $chip"
        gh issue create -R "$REPO" --title "Test matrix: ${commit:0:12} on Apple $(tr 'm' 'M' <<< "$chip")" \
            --body "$(task_body "$commit" "$chip" "$REPO")" \
            --label "$(label task)" --label "$(label open)" --label "$(chip_label "$chip")"
    done
}

# Re-reads each accepted result from its issue and re-checks it, so the
# report only ever contains results that match the schema.
cmd_report() {
    gh issue list -R "$REPO" --state closed --label "$(label "done")" --limit 1000 \
        --json number,closedAt,body,author,assignees |
        jq -c '.[] | {n: .number, closed: .closedAt, body, author: .author.login, who: (.assignees[0].login // "")}' |
        while read -r issue; do
            local n closed who task body json
            n=$(jq -r .n <<< "$issue")
            closed=$(jq -r .closed <<< "$issue")
            who=$(jq -r .who <<< "$issue")
            is_maintainer "$(jq -r .author <<< "$issue")" || continue
            task=$(parse_task "$(jq -r .body <<< "$issue")") || continue
            body=$(gh api --paginate "repos/$REPO/issues/$n/comments?per_page=100" |
                jq -rs --arg w "$who" '[add // [] | .[] | select(.user.login == $w and (.body | startswith("/result")))] | last | .body // empty')
            json=$(result_json "$body") || continue
            validate_result "$json" "${task% *}" "${task#* }" > /dev/null || continue
            jq -c --argjson n "$n" --arg closed "$closed" '. + {n: $n, closed: $closed}' <<< "$json"
        done | report_markdown
    printf '\n## Findings\n\n'
    gh issue list -R "$REPO" --state all --label "$(label finding)" --limit 1000 --json number,state,labels,assignees |
        jq -r --arg l "$(label leased)" --arg r "$(label regressed)" '
            (map(select(.state == "OPEN" and (.assignees | length) == 0)) | length) as $open
            | (map(select(.state == "OPEN" and any(.labels[]; .name == $l))) | length) as $claimed
            | (map(select(.state == "CLOSED")) | length) as $closed
            | (map(select(.state == "OPEN" and any(.labels[]; .name == $r))) | length) as $regressed
            | "\($open) open, \($claimed) being worked on, \($closed) closed, \($regressed) regressed.\n\n| Topic | Open | Closed |\n|---|---|---|\n"
            + ([.[] | {t: ([.labels[].name | select(startswith("fleet:topic:")) | ltrimstr("fleet:topic:")] | first // "other"), s: .state}]
               | group_by(.t) | map("| \(.[0].t) | \(map(select(.s == "OPEN")) | length) | \(map(select(.s == "CLOSED")) | length) |") | join("\n"))'
}

case "${1:-}" in
    labels) cmd_labels ;;
    report) cmd_report ;;
    tasks)
        shift
        cmd_tasks "$@"
        ;;
    *)
        sed -n '2,7p' "$0" >&2
        exit 2
        ;;
esac
