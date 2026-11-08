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
# different, older build). The 2.x line is published only on opencode.ai.
# The one machine-readable version source is the redirect chain from the stable
# channel: it now 302s through an update API hop to
# `.../files/bin/<version>/...`, and that `/files/bin/<version>/` segment is
# what `get_latest_version` parses. The intermediate hop rejects HEAD (405),
# so the check follows the chain with a GET range request (`curl -sS -D- -o
# /dev/null -r 0-0 -L`) rather than `-I`. Two consequences:
#   * `parse_field` is dropped. It exists only to pull a field out of a GitHub
#     JSON body that may embed raw newlines (which would make the body
#     invalid JSON for `jq`); redirect headers have no such problem and are
#     parsed with `sed` instead.
#   * `with_retry` keys off a missing `/files/bin/` location in the collected
#     headers rather than GitHub's "Not Found" body. The stable endpoint
#     intermittently fails to resolve (observed in practice), so retrying is
#     what makes the check reliable rather than falsely reporting "already up
#     to date".
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

        # `curl -sS -D- -o /dev/null -r 0-0 -L` against the stable channel:
        # success is a redirect chain whose collected headers carry a
        # `Location:` pointing at `/files/bin/<version>/...`. A missing one
        # means the redirect is not resolving yet (a new release mid-publish),
        # so retry rather than report a bogus "up to date". The intermediate
        # hop rejects HEAD (405), so the caller uses a GET range request.
        if echo "$output" | grep -qE '/files/bin/[^/]+/'; then
            echo "[TRACE] [cmd=$*] output: $output" 1>&2
            echo "$output" | tr -d '\000-\037'
            return $status
        fi

        count=$((count + 1))
        echo "attempt $count/$retries: no '/files/bin/' location in redirect chain, retrying..." >&2
        sleep 1
    done

    echo "max retries reached. last output: $output (cmd=$*)" >&2
    exit 1
}

# The stable channel now 302s through an update API hop:
#   $download_base/linux-x64-deb
#     -> https://opencode.ai/update/api/latest/desktop/opencode/opencode-desktop-linux-amd64.deb
#     -> https://opencode.ai/files/bin/<version>/opencode-desktop-linux-amd64.deb
# The intermediate hop rejects HEAD (405), so we follow the chain with a GET
# range request and parse the version from the `/files/bin/<version>/` segment
# present in the collected redirect headers.
get_latest_version() {
    echo "RESOLVING STABLE CHANNEL REDIRECT" 1>&2
    headers=$(with_retry curl -sS -D- -o /dev/null -r 0-0 -L "$download_base/linux-x64-deb")

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