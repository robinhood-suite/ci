#! /bin/bash
#
# SPDX-License-Identifier: MIT
#
# author: Quentin Bouget <quentin.bouget@cea.fr>

################################################################################
#                                   DEFAULTS                                   #
################################################################################

instance=review.gerrithub.io
project=cea-hpc/robinhood
branch=v4

################################################################################
#                                  UTILITIES                                   #
################################################################################

# cf. sysexits.h
EX_USAGE=64
EX_DATAERR=65
EX_NOINPUT=66

program="${BASH_SOURCE[0]##*/}"
program="${program%.*}"

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

id2refname()
{
    # If "$1" is a commit id, pick the revision indexed with it
    local revfilter='(.[] | select(.key | test("^'"$1"'")))'

    # If "$1" is a change number... Is there a revision number associated to it?
    local revision
    IFS=/ read -r change revision <<< "$1"

    if [[ $revision ]]; then
        # Yes => Pick the revision that matches
        revfilter+=" // (.[] | select(.value._number == $revision))"
    else
        # No => Pick the most recent change
        revfilter+=" // (sort_by(.value._number) | last)"
    fi

    local filter="$change+project:$project+branch:$branch"
    curl --silent "$url/changes/?q=$filter&n=1&o=ALL_REVISIONS" | tail -n +2 |
        jq --exit-status --raw-output \
            ".[].revisions | to_entries | $revfilter | .value.ref"
}

usage()
{
    printf 'usage: %s [-h] [-g INSTANCE] [-p PROJECT] [-b BRANCH] {COMMIT | URL | CHANGE}

Build and analyze a patch submitted for review on gerrit

positional parameters:
    CHANGE  a gerrit change ID + optionnaly a revision number (eg. 123456/7)
    COMMIT  an optionally partial commit identifier (sha-1)
    URL     the full URL of a gerrit patch

optional parameters:
    -b, --branch BRANCH    the branch of PROJECT where the change should be
    -g, --gerrit INSTANCE  the instance of gerrit to connect to
                           (eg. review.gerrithub.io)
    -h, --help             show this message and exit
    -p, --project PROJECT  the name of the project where the change should be
' "$program"
}

################################################################################
#                                     CLI                                      #
################################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
    -b|--branch)
        [[ $# -gt 1 ]] || die $EX_USAGE "missing BRANCH after %s" "$1"
        branch="$2"
        shift
        ;;
    -g|--gerrit)
        [[ $# -gt 1 ]] || die $EX_USAGE "missing INSTANCE after %s" "$1"
        instance="$2"
        shift
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    -p|--project)
        [[ $# -gt 1 ]] || die $EX_USAGE "missing PROJECT after %s" "$1"
        project="$2"
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

[[ $# -gt 1 ]] && die $EX_USAGE "unexpected argument(s): %s" "${*:2}"
[[ $# -lt 1 ]] && die $EX_USAGE "missing a COMMIT, a URL or a CHANGE"

if [[ $1 =~ ^https://* ]]; then
    # Extract a change from the URL while checking a few things
    set -- "${1#https://}"
    [[ ${1%%/c/*} == "$instance" ]] ||
        die $EX_DATAERR "url mismatch: '%s' != '%s'" "${1%%/c/*}" "$instance"
    set -- "${1#*/c/}"
    [[ ${1%/+/*} == "$project" ]] ||
        die $EX_DATAERR "url mismatch: '%s' != '%s'" "${1%/+/*}" "$project"
    set -- "${1##*/+/}"
fi

url=https://"$instance"
refname="$(id2refname "$1")" ||
    die $EX_NOINPUT "'%s' resolves to an empty refname" "$1"

################################################################################
#                                     MAIN                                     #
################################################################################

# From now on, any error is considered fatal to the build
set -o errexit # <=> set -e

# The build will run in a temporary directory
builddir=$(mktemp --directory --tmpdir "$program"-build-"${1/\//@}"-XXXXXXXXX)
trap -- "rm -rf '$builddir'" EXIT
cd "$builddir"

# Fetch the change
git init .
git fetch --quiet "$url/$project" "$refname"

# Check it out
git switch --detach FETCH_HEAD
git log -n 1

# Build it
meson --buildtype=release -Db_sanitize=address,undefined builddir
ninja -C builddir/ test
ninja -C builddir/ scan-build
