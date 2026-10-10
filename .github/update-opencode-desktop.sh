#!/bin/sh
# Update versions.nix from the opencode.ai stable download channel.
# Usage: update-opencode-desktop.sh [--ci] [--only-check]
#   --ci: enable CI mode (run `nix flake update`, append outputs to $GITHUB_OUTPUT).
#   --only-check: dry-run, emit should_update, exit without mutating anything.
#
# Contract mirrors helium-nix .github/update-helium.sh: download_base at the
# top, with_retry, get_current_version grep, `nix store prefetch-file`,
# write_versions_nix heredoc, main() emitting should_update/version/
# commit_message<<delimiter to $GITHUB_OUTPUT.
#
# Upstream-specific deviation. Helium resolves its version from the GitHub
# releases API, but OpenCode publishes no GitHub releases for the 2.x desktop
# line (anomalyco/opencode tags stop at v1.x, whose desktop artifact is a
# different, older build). The 2.x line is published only on opencode.ai,
# where `https://opencode.ai/update/api/latest/desktop/opencode` answers
# `{"error code: 1101}`. The one machine-readable version source is the
# `Location` header of the stable channel redirect, so that is what
# `get_latest_version` reads here. Two consequences:
#   * `parse_field` is dropped. It exists only to pull a field out of a GitHub
#     JSON body that may embed raw newlines (which would make the body
#     invalid JSON for `jq`); a redirect header has no such problem and is
#     parsed with `sed` instead.
#   * with_retry keys off a missing `location:` header rather than GitHub's
#     "Not Found" body. The stable endpoint intermittently answers 500 to
#     HEAD (observed in practice), so retrying is what makes the check
#     reliable rather than falsely reporting "already up to date".
#
# versions.nix stays the sole version source.

# `download_base` must stay in sync with the URL in
# packages/opencode-desktop/package.nix; both are served from the same
# versioned directory tree.
download_base="https://opencode.ai/download/stable"

ci=false
if echo "$@" | grep -qoE '(--ci)'; then
    ci=true
fi

only_check=false
if echo "$@" | grep -qoE '(--only-check)'; then
    only_check=true
fi

with_retry() {
    retries=5
    count=0
    output=""
    status=0

    while [ $count -lt $retries ]; do
        output=$("$@" 2>&1)
        status=$?

        # `curl -I` against the stable channel: success is a 3xx carrying a
        # `location:` header. A missing one means the redirect is not
        # resolving yet (a new release mid-publish), so retry rather than
        # report a bogus "up to date".
        if echo "$output" | grep -qiE '^location:'; then
            echo "[TRACE] [cmd=$*] output: $output" 1>&2
            echo "$output" | tr -d '\000-\037'
            return $status
        fi

        count=$((count + 1))
        echo "attempt $count/$retries: no 'location:' header in redirect, retrying..." >&2
        sleep 1
    done

    echo "max retries reached. last output: $output (cmd=$*)" >&2
    exit 1
}

# The stable channel 302s to
# https://opencode.ai/files/bin/<version>/opencode-desktop-linux-amd64.deb
# on every published release, so the version is the path segment between
# `files/bin/` and the filename.
get_latest_version() {
    echo "RESOLVING STABLE CHANNEL REDIRECT" 1>&2
    headers=$(with_retry curl -sSI "$download_base/linux-x64-deb")

    version=$(echo "$headers" | sed -n 's|.*/files/bin/\([^/]*\)/.*|\1|p' | head -1 | tr -d '\r\n')

    if [ -z "$version" ]; then
        echo "Error: could not parse a version from the stable redirect:" >&2
        echo "$headers" >&2
        exit 1
    fi

    echo "$version"
}

get_current_version() {
    grep -oE 'version = "[^"]+";' versions.nix | sed 's/version = "//;s/";//'
}

prefetch() {
    nix store prefetch-file --hash-type sha256 --json "$1" | jq -r '.hash'
}

update_flake() {
    echo "Updating flake" >&2
    output=$(nix flake update 2>&1)
    status=$?
    echo "$output" | grep '^warning:' >&2 || true
    echo "$output" | grep -v '^warning:' || true
    return $status
}

write_versions_nix() {
    cat > versions.nix << EOF
# Machine-updated by .github/update-opencode-desktop.sh — do not edit by hand.
{
  version = "$1";
  systems = {
    x86_64-linux = {
      arch = "amd64";
      deb = "$2";
    };
    aarch64-linux = {
      arch = "arm64";
      deb = "$3";
    };
  };
}
EOF
}

main() {
    set -e

    echo "Fetching latest OpenCode desktop release..."
    remote_version=$(get_latest_version)

    if ! echo "$remote_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
        echo "Error: unexpected version format: ${remote_version}" >&2
        exit 1
    fi

    # Upstream paths carry the bare version with no `v` prefix (unlike the
    # GitHub tags helium reads). versions.nix stores that same bare version;
    # the workflow tag step re-adds the `v` for the FlakeHub tag.
    semantic_version="$remote_version"

    local_version=$(get_current_version)

    echo "Checking version... local=$local_version remote=$semantic_version"

    if [ "$local_version" = "$semantic_version" ]; then
        echo "Local OpenCode desktop version is up to date"
        if $only_check && $ci; then
            echo "should_update=false" >> "$GITHUB_OUTPUT"
        fi
        exit 0
    fi

    echo "Local OpenCode desktop version is outdated, updating from $local_version to $semantic_version"

    if $only_check; then
        if $ci; then
            echo "should_update=true" >> "$GITHUB_OUTPUT"
        else
            echo "should_update=true"
        fi
        exit 0
    fi

    echo "Prefetching new hashes..."
    new_x86_64_deb=$(prefetch "https://opencode.ai/files/bin/${semantic_version}/opencode-desktop-linux-amd64.deb")
    new_aarch64_deb=$(prefetch "https://opencode.ai/files/bin/${semantic_version}/opencode-desktop-linux-arm64.deb")

    echo "Updating versions.nix..."
    write_versions_nix \
    "$semantic_version" \
    "$new_x86_64_deb" \
    "$new_aarch64_deb"

    echo "Updated OpenCode desktop from $local_version to $semantic_version"

    if $ci; then
        update_output=$(update_flake)
    else
        update_flake
    fi

    if $ci; then
        delimiter="EOF_$(date +%s)_$$"

        {
            echo "commit_message<<${delimiter}"
            echo "chore(update): opencode-desktop to ${semantic_version}"
            if [ -n "$update_output" ]; then
                echo ""
                echo "$update_output"
            fi
            echo "${delimiter}"
            echo "should_update=true"
            echo "version=${semantic_version}"
        } >> "$GITHUB_OUTPUT"
    fi
}

main