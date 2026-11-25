#!/bin/bash
# The GitHub Actions side of the Mac test fleet (see docs/fleet.md).
# Leases tasks and findings through issue comments, checks results, files
# failure signatures and slowdowns as deduplicated findings, opens automatic
# test rounds, screens free text in fleet issues and expires stale leases.
# Run by the fleet-* workflows with GH_TOKEN set. Never evaluates comment
# text: comments are only matched against fixed patterns and the schema.
#
# Usage: queue.sh event    (reads GITHUB_EVENT_NAME and GITHUB_EVENT_PATH)
#        queue.sh expire
#        queue.sh autotask
# shellcheck disable=SC2016,SC2001 # literal backticks, jq and GraphQL in single quotes
set -euo pipefail
# shellcheck source=tools/fleet/lib.sh
. "$(dirname "$0")/lib.sh"

REPO="${GITHUB_REPOSITORY:?}"
LEGAL_URL="https://github.com/$REPO/blob/main/docs/fleet-legal.md"
FLEET_URL="https://github.com/$REPO/blob/main/docs/fleet.md"

api() { gh api -H "Accept: application/vnd.github+json" "$@"; }
reply() { api "repos/$REPO/issues/$1/comments" -f body="$2" > /dev/null; }
react() { api "repos/$REPO/issues/comments/$1/reactions" -f content="$2" > /dev/null; }
add_label() { api "repos/$REPO/issues/$1/labels" -f "labels[]=$2" > /dev/null; }
remove_label() { api -X DELETE "repos/$REPO/issues/$1/labels/$2" > /dev/null 2>&1 || true; }
unassign() { api -X DELETE "repos/$REPO/issues/$1/assignees" -f "assignees[]=$2" > /dev/null; }
delete_comment() { api -X DELETE "repos/$REPO/issues/comments/$1" > /dev/null; }
close_issue() { api -X PATCH "repos/$REPO/issues/$1" -f state=closed -f state_reason="$2" > /dev/null; }
hide_comment() {
    api graphql -f id="$1" -f query='
        mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: OFF_TOPIC}) { clientMutationId } }' > /dev/null
}
issue_comments() { api --paginate "repos/$REPO/issues/$1/comments?per_page=100" | jq -s 'add // []'; }

reopen_lease() { # ISSUE LOGIN
    [ -n "$2" ] && unassign "$1" "$2"
    remove_label "$1" "$(label leased)"
    add_label "$1" "$(label open)"
}

# ISSUE_JSON -> "task COMMIT CHIP", "finding SIG TEST TOPIC" or nothing.
issue_kind() {
    local author body parsed
    author=$(jq -r .user.login <<< "$1")
    body=$(jq -r '.body // ""' <<< "$1")
    if is_trusted_author "$author" && parsed=$(parse_task "$body"); then
        echo "task $parsed"
    elif is_bot_login "$author" && parsed=$(parse_finding "$body"); then
        echo "finding $parsed"
    fi
    return 0
}

lease_hours_for() { # KIND
    if [ "$1" = finding ]; then conf .lease_hours_finding; else conf .lease_hours; fi
}

# The accepted /result JSON of a closed task, or nothing.
accepted_result() { # ISSUE_JSON
    local n who kind body json
    n=$(jq -r .number <<< "$1")
    who=$(jq -r '.assignees[0].login // ""' <<< "$1")
    kind=$(issue_kind "$1")
    [ "${kind%% *}" = task ] && [ -n "$who" ] || return 1
    # shellcheck disable=SC2086 # fixed-format fields
    set -- $kind
    body=$(issue_comments "$n" | jq -r --arg w "$who" \
        '[.[] | select(.user.login == $w and (.body | startswith("/result")))] | last | .body // empty')
    json=$(result_json "$body") || return 1
    validate_result "$json" "$2" "$3" > /dev/null || return 1
    printf '%s\n' "$json"
}

# --- findings -------------------------------------------------------------

FINDINGS='[]'
load_findings() {
    FINDINGS=$(api --paginate "repos/$REPO/issues?state=all&labels=$(label finding)&per_page=100" |
        jq -sc 'add // [] | map(select(.pull_request == null and (.user.login | startswith("github-actions"))))')
}
findings_with() { # SIG -> issue numbers, oldest first
    jq -r --arg s "$1" 'map(select((.body // "") | contains("\nsig: \($s)\n"))) | map(.number) | sort | .[]' <<< "$FINDINGS"
}

# Files one sighting of a signature. Opens the finding the first time, and
# reopens it as regressed if it was closed. Duplicates from two results
# landing at once collapse onto the oldest issue.
upsert_finding() { # SIG TEST TOPIC SIGHTING
    local sig=$1 test=$2 topic=$3 sighting=$4 n created state assignee
    n=$(findings_with "$sig" | head -n 1)
    if [ -z "$n" ]; then
        created=$(api "repos/$REPO/issues" -f title="Finding ($topic): $test" \
            -f body="$(finding_body "$sig" "$test" "$topic" "$REPO")" \
            -f "labels[]=$(label finding)" -f "labels[]=$(label open)" -f "labels[]=fleet:topic:$topic" --jq .number)
        load_findings
        n=$(findings_with "$sig" | head -n 1)
        if [ -n "$n" ] && [ "$n" != "$created" ]; then
            reply "$created" "Duplicate of #$n."
            close_issue "$created" not_planned
        fi
        n=${n:-$created}
    else
        state=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .state' <<< "$FINDINGS")
        if [ "$state" = closed ]; then
            assignee=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .assignees[0].login // ""' <<< "$FINDINGS")
            api -X PATCH "repos/$REPO/issues/$n" -f state=open -f state_reason=reopened > /dev/null
            reopen_lease "$n" "$assignee"
            add_label "$n" "$(label regressed)"
            sighting="Seen again after this was closed, so it has been reopened as a regression. $sighting"
            load_findings
        fi
    fi
    reply "$n" "$sighting"
}

record_findings() { # RESULT TASK_ISSUE
    local json=$1 task=$2 where sig test topic
    where=$(jq -r '"`\(.upstream_commit[0:12])` · \(.chip) · macOS \(.macos)"' <<< "$json")
    load_findings
    while read -r sig test topic; do
        [ -n "$sig" ] && upsert_finding "$sig" "$test" "$topic" "Seen in #$task: $where."
    done < <(jq -r '.failures[] | "\(.sig) \(.test) \(.topic)"' <<< "$json")
}

# Compares a result with the latest accepted result for an older commit on
# the same chip family, and files test binaries that got much slower.
record_slowdowns() { # RESULT TASK_ISSUE CHIP COMMIT
    local json=$1 task=$2 chip=$3 commit=$4 prev="" candidate key old new
    while read -r candidate; do
        [ -n "$candidate" ] || continue
        [ "$(jq -r .number <<< "$candidate")" = "$task" ] && continue
        [[ $(issue_kind "$candidate") == "task $commit "* ]] && continue
        if prev=$(accepted_result "$candidate"); then break; fi
        prev=""
    done < <(api "repos/$REPO/issues?state=closed&labels=$(label "done"),$(chip_label "$chip")&sort=updated&direction=desc&per_page=20" |
        jq -c 'sort_by(.closed_at) | reverse | .[]')
    [ -n "$prev" ] || return 0
    load_findings
    while IFS="$(printf '\t')" read -r key old new; do
        [ -n "$key" ] || continue
        upsert_finding "$(signature "perf"$'\n'"$key")" "$key" performance \
            "Slower in #$task: $key took $new s at \`${commit:0:12}\` on $chip, against $old s at \`$(jq -r '.upstream_commit[0:12]' <<< "$prev")\`."
    done < <(slowdowns "$prev" "$json")
}

# --- commands -------------------------------------------------------------

handle_command() { # ISSUE COMMENT_ID LOGIN COMMAND BODY
    local n=$1 cid=$2 who=$3 cmd=$4 body=$5
    local issue state labels assignee kind kind_label
    issue=$(api "repos/$REPO/issues/$n")
    state=$(jq -r .state <<< "$issue")
    labels=$(jq -c '[.labels[].name]' <<< "$issue")
    assignee=$(jq -r '.assignees[0].login // ""' <<< "$issue")
    has() { jq -e --arg l "$1" 'index($l) != null' > /dev/null <<< "$labels"; }

    kind=$(issue_kind "$issue")
    if [ -z "$kind" ]; then
        react "$cid" -1
        reply "$n" "This issue is not a valid fleet task or finding, so the command was ignored."
        return
    fi
    # shellcheck disable=SC2086 # fixed-format fields
    set -- $kind
    kind_label=$(label "$1")

    case "$cmd" in
        claim)
            if [ "$state" != open ] || ! has "$(label open)" || [ -n "$assignee" ]; then
                react "$cid" -1
                reply "$n" "@$who this is not open for leasing. Run \`tools/fleet/fleet.sh next\` or \`fleet.sh findings\` for another one."
                return
            fi
            local other
            other=$(api "repos/$REPO/issues?state=open&assignee=$who&labels=$(label leased),$kind_label" --jq '.[0].number // empty')
            if [ -n "$other" ]; then
                react "$cid" -1
                reply "$n" "@$who you already hold a lease on #$other. Finish it or \`/release\` it first."
                return
            fi
            api "repos/$REPO/issues/$n/assignees" -f "assignees[]=$who" > /dev/null
            local assignees winner
            assignees=$(api "repos/$REPO/issues/$n" --jq '[.assignees[].login]')
            if ! jq -e --arg w "$who" 'index($w) != null' > /dev/null <<< "$assignees"; then
                react "$cid" -1
                reply "$n" "@$who GitHub would not assign this issue to you, so the lease was not granted."
                return
            fi
            # Two claims at once: the earliest /claim comment wins, in every run.
            if [ "$(jq length <<< "$assignees")" -gt 1 ]; then
                winner=$(issue_comments "$n" | jq -r --argjson a "$assignees" \
                    '[.[] | select((.body | test("^\\s*/claim\\s*$")) and (.user.login as $u | $a | index($u) != null))] | first | .user.login')
                while read -r a; do
                    [ "$a" = "$winner" ] || unassign "$n" "$a"
                done < <(jq -r '.[]' <<< "$assignees")
                if [ "$winner" != "$who" ]; then
                    react "$cid" -1
                    reply "$n" "@$who @$winner claimed this first."
                    return
                fi
            fi
            remove_label "$n" "$(label open)"
            add_label "$n" "$(label leased)"
            local hours until
            hours=$(lease_hours_for "$1")
            until=$(date -u -d "+$hours hours" '+%Y-%m-%d %H:%M UTC')
            react "$cid" +1
            if [ "$1" = task ]; then
                reply "$n" "Leased to @$who until $until. \`tools/fleet/fleet.sh run $n\` keeps it alive with \`/beat\`. Submit with \`fleet.sh submit $n\`, or hand it back with \`fleet.sh release $n <reason>\`."
            else
                reply "$n" "@$who is working on this until $until. Comment \`/beat\` to keep the lease, reference this issue from the fix's pull request, or \`/release other\` to hand it back."
            fi
            ;;
        beat)
            if [ "$assignee" = "$who" ] && has "$(label leased)"; then react "$cid" +1; else react "$cid" -1; fi
            ;;
        release\ *)
            if { [ "$assignee" = "$who" ] || is_maintainer "$who"; } && has "$(label leased)"; then
                reopen_lease "$n" "$assignee"
                react "$cid" +1
                reply "$n" "Released (${cmd#release }). This is open again."
            else
                react "$cid" -1
            fi
            ;;
        result)
            local json errors="" commit=${2:-} chip=${3:-}
            if [ "$1" != task ] || [ "$assignee" != "$who" ] || ! has "$(label leased)"; then
                delete_comment "$cid"
                reply "$n" "@$who a result was removed because you do not hold the lease on this task."
                return
            fi
            if ! json=$(result_json "$body") || ! errors=$(validate_result "$json" "$commit" "$chip"); then
                [ -n "$errors" ] || errors="the comment must be /result followed by one json block and nothing else"
                delete_comment "$cid"
                reply "$n" "@$who your result was removed because it does not match the schema:
$(sed 's/^/- /' <<< "$errors")

Post results with \`tools/fleet/fleet.sh submit $n\` only. See [docs/fleet.md]($FLEET_URL)."
                return
            fi
            local summary
            summary=$(jq -r '
                def row($n; $c; $t): if $c == null then "| \($n) | - | - | - | - |"
                    else "| \($n) | \($c.passed) | \($c.failed) | \($c.ignored) | \($t // "-") s |" end;
                "Result accepted.\n\n**\(.chip)** · `\(.hw_model)` · macOS \(.macos) · Game Porting Toolkit \(.gptk) · setup \(.setup) (\(.timings.setup // "-") s)\n\n"
                + "| Suite | Passed | Failed | Ignored | Wall time |\n|---|---|---|---|---|\n"
                + row("Native"; .native; .timings.native) + "\n" + row("Wine + D3DMetal"; .wine; .timings.wine)
                + (if (.failures | length) > 0
                   then "\n\nFailures (each is filed as a finding):\n\n| Test | Topic | Signature |\n|---|---|---|\n"
                       + (.failures[:30] | map("| `\(.test)` | \(.topic) | `\(.sig)` |") | join("\n")) else "" end)' <<< "$json")
            remove_label "$n" "$(label leased)"
            add_label "$n" "$(label "done")"
            if result_failing "$json"; then add_label "$n" "$(label failing)"; else add_label "$n" "$(label passing)"; fi
            react "$cid" +1
            reply "$n" "$summary"
            close_issue "$n" completed
            record_findings "$json" "$n"
            record_slowdowns "$json" "$n" "$chip" "$commit"
            ;;
    esac
}

# --- moderation -----------------------------------------------------------

moderate_comment() { # ISSUE COMMENT_ID NODE_ID LOGIN BODY
    local verdict
    verdict=$(moderate "$5")
    case "$verdict" in
        delete\ *)
            delete_comment "$2"
            add_label "$1" "$(label review)"
            reply "$1" "@$4 a comment was removed (${verdict#delete }). Fleet issues never carry game material or links to it. See [docs/fleet-legal.md]($LEGAL_URL)."
            ;;
        hide\ *)
            hide_comment "$3"
            add_label "$1" "$(label review)"
            reply "$1" "A comment was hidden for maintainer review (${verdict#hide }). See [docs/fleet-legal.md]($LEGAL_URL)."
            ;;
    esac
}

moderate_issue() { # ISSUE TEXT
    local verdict
    verdict=$(moderate "$2")
    case "$verdict" in
        delete\ *)
            api -X PATCH "repos/$REPO/issues/$1" -f title="Removed by the fleet moderation bot" \
                -f body="The text of this issue was removed (${verdict#delete }). See [docs/fleet-legal.md]($LEGAL_URL). Maintainers: delete the earlier revision from the edit history." \
                -f state=closed -f state_reason=not_planned > /dev/null
            add_label "$1" "$(label review)"
            api -X PUT "repos/$REPO/issues/$1/lock" -f lock_reason=off-topic > /dev/null
            ;;
        hide\ *)
            add_label "$1" "$(label review)"
            api -X PUT "repos/$REPO/issues/$1/lock" -f lock_reason=off-topic > /dev/null
            reply "$1" "This issue was locked for maintainer review (${verdict#hide }). See [docs/fleet-legal.md]($LEGAL_URL)."
            ;;
    esac
}

# --- entry points ---------------------------------------------------------

handle_event() {
    local ev=${GITHUB_EVENT_PATH:?} action n
    action=$(jq -r .action "$ev")
    n=$(jq -r .issue.number "$ev")
    [ "$(jq -r .sender.type "$ev")" = Bot ] && return 0
    [ "$(jq -r '.issue.pull_request != null' "$ev")" = true ] && return 0

    if [ "${GITHUB_EVENT_NAME:?}" = issues ]; then
        moderate_issue "$n" "$(jq -r '.issue.title + "\n" + (.issue.body // "")' "$ev")"
        return 0
    fi

    local cid node who body is_fleet cmd
    cid=$(jq -r .comment.id "$ev")
    node=$(jq -r .comment.node_id "$ev")
    who=$(jq -r .comment.user.login "$ev")
    body=$(jq -r '.comment.body // ""' "$ev")
    valid_login "$who" || return 0
    is_fleet=$(jq -r --arg t "$(label task)" --arg f "$(label finding)" \
        '[.issue.labels[].name] | (index($t) != null) or (index($f) != null)' "$ev")

    if [ "$action" = created ] && [ "$is_fleet" = true ]; then
        cmd=$(parse_command "$body")
        if [ -n "$cmd" ]; then
            handle_command "$n" "$cid" "$who" "$cmd" "$body"
            return 0
        fi
    fi
    moderate_comment "$n" "$cid" "$node" "$who" "$body"
}

expire_leases() {
    local now n who kind hours last age
    now=$(date -u +%s)
    while read -r n who kind; do
        [ -n "$n" ] || continue
        hours=$(lease_hours_for "$kind")
        last=$(issue_comments "$n" | jq -r --arg w "$who" '[.[] | select(.user.login == $w)
            | select(.body | test("^\\s*/(claim|beat)\\s*$")) | .created_at] | max // empty')
        if [ -z "$last" ]; then
            age=$((hours * 3600 + 1))
        else
            age=$((now - $(date -u -d "$last" +%s)))
        fi
        if [ "$age" -gt $((hours * 3600)) ]; then
            [ "$who" = - ] && who=""
            reopen_lease "$n" "$who"
            reply "$n" "The lease expired after $hours hours without a \`/beat\`. This is open again."
        fi
    done < <(api --paginate "repos/$REPO/issues?state=open&labels=$(label leased)&per_page=100" |
        jq -rs --arg f "$(label finding)" 'add // [] | .[]
            | "\(.number) \(.assignees[0].login // "-") \(if ([.labels[].name] | index($f)) then "finding" else "task" end)"')
}

# Opens a round of test-matrix tasks for the commit main points to, unless
# that commit already has tasks or the last round is too recent. Open,
# unleased tasks for older commits are closed as superseded.
auto_round() {
    local head tasks newest age hours chip n
    head=$(api "repos/$REPO/commits/main" --jq .sha)
    hours=$(conf .auto_round_hours)
    tasks=$(api --paginate "repos/$REPO/issues?state=all&labels=$(label task)&sort=created&direction=desc&per_page=100" |
        jq -sc 'add // [] | map(select(.pull_request == null))')
    if jq -e --arg h "$head" 'any(.[]; (.body // "") | contains("\ncommit: \($h)\n"))' > /dev/null <<< "$tasks"; then
        echo "main ($head) already has tasks"
        return 0
    fi
    newest=$(jq -r 'map(.created_at) | max // empty' <<< "$tasks")
    if [ -n "$newest" ]; then
        age=$(($(date -u +%s) - $(date -u -d "$newest" +%s)))
        if [ "$age" -lt $((hours * 3600)) ]; then
            echo "last round is less than $hours hours old"
            return 0
        fi
    fi
    while read -r n; do
        [ -n "$n" ] || continue
        reply "$n" "Superseded by a new round for \`${head:0:12}\`."
        remove_label "$n" "$(label open)"
        close_issue "$n" not_planned
    done < <(jq -r --arg o "$(label open)" '.[] | select(.state == "open" and ([.labels[].name] | index($o))) | .number' <<< "$tasks")
    for chip in $(conf '.chips[]'); do
        api "repos/$REPO/issues" -f title="Test matrix: ${head:0:12} on Apple $(tr 'm' 'M' <<< "$chip")" \
            -f body="$(task_body "$head" "$chip" "$REPO")" \
            -f "labels[]=$(label task)" -f "labels[]=$(label open)" -f "labels[]=$(chip_label "$chip")" > /dev/null
    done
    echo "opened a round for $head"
}

case "${1:-}" in
    event) handle_event ;;
    expire) expire_leases ;;
    autotask) auto_round ;;
    *)
        echo "usage: queue.sh event|expire|autotask" >&2
        exit 2
        ;;
esac
