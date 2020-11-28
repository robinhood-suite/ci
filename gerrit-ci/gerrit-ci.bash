#! /bin/bash
#
# SPDX-License-Identifier: MIT
#
# author: Quentin Bouget <quentin.bouget@cea.fr>

################################################################################
#                                  UTILITIES                                   #
################################################################################

# cf. sysexits.h
EX_USAGE=64
EX_NOINPUT=66
EX_TEMPFAIL=75

program="${BASH_SOURCE[0]##*/}"
program="${program[0]%.*}"

tmpdir="${TMPDIR:-/tmp}/$program"

die()
{
    local -i code=${1:-$?}
    shift

    exec 2>&1

    case "$code" in
    $EX_USAGE)
        declare -F usage >/dev/null 2>&1 && usage
        [[ $# -gt 0 ]] && printf '\n'
        ;;
    esac

    [[ $# -gt 0 ]] && printf "%s: $1\n" "$program" "${@:2}" >&2

    exit "$code"
}

revcheck()
{
    curl --silent "$url/changes/?q=$1+$filter" | tail -n +2 |
        jq '.[]' --exit-status > /dev/null
}

gerrit()
{
    ssh -p "$sshport" -l "$sshuser" "$sshname" gerrit "$@"
}

sshconfig()
{
    ssh -G "$sshname" | grep "^$1 " | cut -d' ' -f2-
}

unverified()
{
    curl --silent "$url/changes/?q=$filter+owner:$sshuser&o=CURRENT_REVISION" |
        tail -n +2 | jq --raw-output '.[].current_revision'
}

usage()
{
    printf 'usage: %s [-h] [-u USER] [-s HOST] [-p PORT] INSTANCE PROJECT BRANCH PROGRAM

Monitor and verify patches submitted on gerrit for a given project/branch

positional arguments:
    BRANCH    the branch of PROJECT to monitor
    INSTANCE  the gerrit instance to monitor (eg. review.gerrithub.io)
    PROGRAM   the program to run that verifies patches, it must accept a commit
              identifier (sha-1) as its first argument
    PROJECT   the project to monitor

optional arguments:
    -h, --help           show this message and exit
    -p, --ssh-port PORT  ssh port of the gerrit instance to connect to
    -s, --ssh-host HOST  the ssh name of the gerrit instance to connect to
    -s, --ssh-user USER  the username to connect to gerrit with
' "$program"
}

################################################################################
#                                     CLI                                      #
################################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
    -p|--ssh-port)
        [[ $# -gt 1 ]] || die $EX_USAGE "missing PORT after %s" "$1"
        sshport="$2"
        shift
        ;;
    -s|--ssh-host)
        [[ $# -gt 1 ]] || die $EX_USAGE "missing HOST after %s" "$1"
        sshname="$2"
        shift
        ;;
    -u|--ssh-user)
        [[ $# -gt 1 ]] || die $EX_USAGE "missing USER after %s" "$1"
        sshuser="$2"
        shift
        ;;
    -[^-]|--?*)
        die 64 "unknown option '%s'" "$1"
        ;;
    --)
        shift
        ;&
    *)
        break 2
    esac
    shift
done

case "$#" in
0)
    die $EX_USAGE "missing a gerrit INSTANCE"
    ;;
1)
    die $EX_USAGE "missing a PROJECT"
    ;;
2)
    die $EX_USAGE "missing a BRANCH"
    ;;
3)
    die $EX_USAGE "missing a PROGRAM"
    ;;
4)
    instance="$1"
    project="$2"
    branch="$3"
    ci="$4"
    ;;
*)
    die $EX_USAGE "unexpected argument(s): %s" "${*:4}"
    ;;
esac

filter="status:open+project:$project+branch:$branch"
url=https://"$instance"

################################################################################
#                                     MAIN                                     #
################################################################################

set -o errexit

# Fetch the ssh configuration with the REST API (only if needed)
[[ $sshname ]] || {
    read -r sshname port < <(curl --silent "$url"/ssh_info && printf '\n')
    sshport="${sshport:-$port}"
}

# Guess the potentially missing username and port
[[ $sshuser ]] || sshuser="$(sshconfig user)"
[[ $sshport ]] || sshport="$(sshconfig port)"

# Check the ssh connection works
gerrit version

# Update `filter' so that it only matches unverified patches
filter+="+label:Verified=0,user=$sshuser"

gerritwatch()
{
    # available events:
    #
    #     assignee-changed     change-abandoned     assignee-changed
    #     change-abandoned     change-deleted       change-merged
    #     change-restored      comment-added        dropped-output
    #     hashtags-changed     project-created      patchset-created
    #     ref-updated          reviewer-added       reviewer-deleted
    #     topic-changed        wip-state-changed    private-state-changed
    #     vote-deleted
    #
    # Each type of event requires a different jq filter.

    # The following events are filtered in:
    #   - comment-added: if the "Verified" label was removed
    #   - patchset-created: new patch
    #   - ref-updated: new version of a patch
    local -A jqfilter=(
        [comment-added]='select(
                .change |
                .project == "'"$project"'" and .branch == "'"$branch"'"
            ) | select(
                .author.username == "'"$sshuser"'"
            ) | select(
                .approvals | .[] |
                .type == "Verified" and .oldValue != "0" and .value == "0"
            ) | .patchSet.revision'
        [patchset-created]='select(
                .uploader.username == "'"$sshuser"'" and (
                    .change
                  | .project == "'"$project"'" and .branch == "'"$branch"'"
                )
            ) | .patchSet.revision'
        [ref-updated]='select(
                .submitter.username == "'"$sshuser"'"
            ) | .refUpdate | select(.project == "'"$project"'")
              | select(.refName | test("meta") | not)
              | select(.refName | test("version") | not)
              | .newRev | select(. | test("^0+$") | not)'
    )

    gerrit stream-events -s comment-added -s patchset-created \
        -s ref-updated 2>/dev/null |
        jq --unbuffered --raw-output \
            'if .type == "comment-added" then
                 '"${jqfilter[comment-added]}"'
             else
                 if .type == "patchset-created" then
                     '"${jqfilter[patchset-created]}"'
                 else
                     if .type == "ref-updated" then
                         '"${jqfilter[ref-updated]}"'
                     else
                         error(["Unexpected gerrit event type:", .type] |
                               join(" "))
                     end
                 end
             end' | # Last minute check (to avoid spurious events)
        while read -r revision; do
            revcheck "$revision" || continue
            printf '%s\n' "$revision"
        done
}

# There should never be more than one running instance per project/branch
mkdir -p "$tmpdir/$project"
trap -- "rm -rf '$tmpdir/$project/$branch'" EXIT
mkdir "$tmpdir/$project/$branch"
cd "$tmpdir/$project/$branch"

runci()
{
    local commit="$1"
    local builddir="$commit"
    local score=0
    local notify=OWNER

    # `builddir' also serves as a lock, preventing multiple concurrent builds
    # of the same commit
    mkdir "$builddir" || return 0
    trap -- "rm -rf '$PWD/$builddir'" EXIT
    cd "$builddir"
    printf "%s: start\n" "$commit"

    (
    set -o errexit

    exec >build.stdout
    exec 2>build.stderr

    TMPDIR="$PWD" "$ci" "$commit"
    )

    case "$?" in
    0)
        printf "%s: success\n" "$commit"
        score=1
        notify=NONE
        ;;
    $EX_NOINPUT)
        printf "%s: skip # resolves to an empty refname\n" "$commit"
        return 0
        ;;
    $EX_TEMPFAIL)
        printf "%s: skip # temporary failure\n" "$commit"
        return 0
        ;;
    *)
        printf "%s: failure\n" "$commit"
        # XXX: It might be useful to keep a trace of the failed builds
        #      but if left unchecked, this might fill a whole disk
        #
        # trap -- "" EXIT
        score=-1
        ;;
    esac

    gerrit review --notify "$notify" --project "$project" --verified "$score" \
        "$commit"
}

# Export runci() and everything it needs to be called by xargs
export branch ci EX_NOINPUT EX_TEMPFAIL project sshname sshport sshuser url
export -f gerrit runci

# The connection to gerrit regularly closes, so we have to put it inside an
# infinite loop.
#
# We might be missing events between two ssh session, so the `unverified | ...'
# part takes care of querying gerrit's REST API for unverified patches.
# This is also useful to process any patch that might have been pushed while the
# CI was down.
#
# XXX: One side effect of the ssh connection closing regularly is that any
#      temporary failure in the build process will be gracefully handled, but if
#      that behaviour were to stop, skipped builds would never be retried.
while true; do
    # Open a connection to the gerrit instance and start collecting events
    coproc gerritwatch
    sleep 5 # Wait for the connection to be established
            # (This also prevents the script from spamming gerrit too hard)

    # Check for any event we might have missed
    unverified |
        xargs --no-run-if-empty --max-args 1 --max-procs 1 -- \
            bash -c 'runci "$1"' "$program"-worker

    # Process events
    xargs --no-run-if-empty --max-args 1 --max-procs "$(nproc)" -- \
        bash -c 'runci "$1"' "$program"-worker <&"${COPROC[0]}"
done
