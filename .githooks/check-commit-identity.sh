#!/usr/bin/env bash
# Guards commit authorship so only the repository owner is ever recorded as
# author/committer, and so no Co-authored-by trailers leak into history.
#
# Usage:
#   check-commit-identity.sh identity            # validate identity git would use now
#   check-commit-identity.sh message <file>      # validate a commit message file
#   check-commit-identity.sh range <rev-range>   # validate existing commits
#
# Configuration (env or git config):
#   COMMIT_ALLOWED_AUTHOR_EMAILS  comma-separated allow list
#   COMMIT_AUTHOR_NAME            expected name shown in remediation output
#   COMMIT_AUTHOR_EMAIL           expected email shown in remediation output
set -euo pipefail

DEFAULT_ALLOWED_EMAILS='yec.santos@gmail.com,75240772+edilsonsantos-co-za@users.noreply.github.com'

git_cfg() { git config --get "$1" 2>/dev/null || true; }

ALLOWED_EMAILS="${COMMIT_ALLOWED_AUTHOR_EMAILS:-$(git_cfg commitAuthorship.allowedEmails)}"
ALLOWED_EMAILS="${ALLOWED_EMAILS:-$DEFAULT_ALLOWED_EMAILS}"
EXPECTED_NAME="${COMMIT_AUTHOR_NAME:-Edilson Santos}"
EXPECTED_EMAIL="${COMMIT_AUTHOR_EMAIL:-yec.santos@gmail.com}"

email_is_allowed() {
    local candidate="$1" allowed entry
    IFS=',' read -r -a allowed <<< "$ALLOWED_EMAILS"
    for entry in "${allowed[@]}"; do
        entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
        [[ -n "$entry" && "$candidate" == "$entry" ]] && return 0
    done
    return 1
}

fail() {
    echo "[commit-identity] ✖ $*" >&2
    return 1
}

remediation() {
    cat >&2 <<EOF
[commit-identity] Fix with:
    git config user.name "${EXPECTED_NAME}"
    git config user.email "${EXPECTED_EMAIL}"
  Allowed author/committer emails: ${ALLOWED_EMAILS}
EOF
}

extract_email() {
    # Extracts the address from a "Name <email> 1700000000 +0200" ident string.
    printf '%s' "$1" | sed -n 's/.*<\(.*\)>.*/\1/p'
}

check_identity() {
    local author_email committer_email status=0
    author_email="$(extract_email "$(git var GIT_AUTHOR_IDENT)")"
    committer_email="$(extract_email "$(git var GIT_COMMITTER_IDENT)")"

    email_is_allowed "$author_email" || { fail "author email '${author_email}' is not permitted." || status=1; }
    email_is_allowed "$committer_email" || { fail "committer email '${committer_email}' is not permitted." || status=1; }

    if [[ "$status" -ne 0 ]]; then
        remediation
        return 1
    fi
    return 0
}

check_message() {
    local message_file="$1"
    [[ -f "$message_file" ]] || return 0

    if grep -Eiq '^[[:space:]]*co-authored-by:' "$message_file"; then
        fail "commit message contains a Co-authored-by trailer; this repository records a single author."
        echo "[commit-identity] Remove the Co-authored-by line(s) and commit again." >&2
        return 1
    fi
    return 0
}

check_range() {
    local status=0 log_output sha author_email committer_email coauthored

    if ! log_output="$(git log --format='%H %ae %ce' "$@" 2>&1)"; then
        fail "unable to inspect commit range '$*': ${log_output}"
        return 1
    fi

    while read -r sha author_email committer_email; do
        [[ -z "${sha:-}" ]] && continue
        if ! email_is_allowed "$author_email"; then
            fail "${sha} has disallowed author email '${author_email}'." || true
            status=1
        fi
        if ! email_is_allowed "$committer_email"; then
            fail "${sha} has disallowed committer email '${committer_email}'." || true
            status=1
        fi
    done <<< "$log_output"

    coauthored="$(git log --format='%H' -i --grep='^[[:space:]]*Co-authored-by:' "$@" 2>/dev/null || true)"
    if [[ -n "$coauthored" ]]; then
        while read -r sha; do
            [[ -z "$sha" ]] && continue
            fail "${sha} contains a Co-authored-by trailer." || true
            status=1
        done <<< "$coauthored"
    fi

    if [[ "$status" -ne 0 ]]; then
        remediation
        return 1
    fi
    return 0
}

mode="${1:-identity}"
case "$mode" in
    identity) check_identity ;;
    message)  check_message "${2:?commit message file required}" ;;
    range)
        shift
        [[ $# -gt 0 ]] || { echo "rev-range required" >&2; exit 2; }
        check_range "$@"
        ;;
    *)
        echo "Usage: $0 {identity|message <file>|range <rev-range...>}" >&2
        exit 2
        ;;
esac
