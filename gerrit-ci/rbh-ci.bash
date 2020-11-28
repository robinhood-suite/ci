#! /bin/bash
#
# SPDX-License-Identifier: MIT
#
# author: Quentin Bouget <quentin.bouget@cea.fr>

################################################################################
#                                   DEFAULTS                                   #
################################################################################

instance=review.gerrithub.io
project=cea-hpc/librobinhood
branch=main
persist=false

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

c_args()
{
    meson introspect --buildoptions "$@" |
        jq '.[] | select(.name == "c_args") | .value | join(" ")'
}

gcc_robot_comments()
{
    local id="$(gcc --version | head -n 1)"
    local runid="${builddir##*-}"

    jq -nR 'def trimpath: . | sub("^(../)*"; "");
        [inputs | fromjson? | .[]] | reduce .[] as $diagnostic ({};
            $diagnostic.locations[0]? as $location
          | ($location.caret.file | trimpath) as $path
          | .[$path] |= (. + [{
                "path": $path,
                "range": ($location | {
                    "start_line": .caret.line,
                    "start_character": (.caret.column - 1),
                    "end_line": (.finish.line // .caret.line),
                    "end_character": (.finish.column // .caret.column)
                }),
                "robot_id": "'"$id"'",
                "robot_run_id": "'"$runid"'",
                "message": $diagnostic.message,
                "fix_suggestions": (if $diagnostic.fixits then [{
                    "description": "(suggest)",
                    "replacements": [$diagnostic.fixits | .[] | {
                        "path": .start.file | trimpath,
                        "range": {
                            "start_line": .start.line,
                            "start_character": (.start.column - 1),
                            "end_line": .next.line,
                            "end_character": (.next.column - 1)
                        },
                        "replacement": .string
                    }]
                }] else [] end)
            }])
        )'
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
                           (default: %s)
    -g, --gerrit INSTANCE  the instance of gerrit to connect to
                           (default: %s)
    -h, --help             show this message and exit
    --persist              keep the build directory and its content
    -p, --project PROJECT  the name of the project where the change should be
                           (default: %s)
' "$program" "${instance:-none}" "${branch:-none}" "${project:-none}"
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
    --persist)
        persist=true
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
$persist || trap -- "rm -rf '$builddir'" EXIT
cd "$builddir"

# Fetch the change
git init .
git fetch --quiet "$url/$project" "$refname"

# Check it out
git switch --detach FETCH_HEAD
git log -n 1

# Build it
CC=gcc meson -Db_sanitize=address,undefined -Dc_args=-fno-sanitize=all gcc-build
if [[ -e /proc/self/fd/3 ]]; then
    (
    c_args=$(c_args gcc-build)
    trap -- "meson configure -Dc_args='$c_args' gcc-build" EXIT

    meson configure -Dc_args="$c_args -fdiagnostics-format=json" gcc-build
    ninja -C gcc-build | gcc_robot_comments >&3
    )
fi
ninja -C gcc-build/ test

CC=clang meson -Db_sanitize=address,undefined -Dc_args=-fno-sanitize=all \
    -Db_lundef=false clang-build
ninja -C clang-build/ test
ninja -C clang-build/ scan-build

meson --buildtype=release release-build
ninja -C release-build/ test

# Build the documentation
find -name '*.rst' -print0 |
    xargs --null --no-run-if-empty --max-args 1 -- bash -c \
        'rst2html --exit-status=2 "$0" > "${0%.rst}".html'
