#!/bin/bash
# Resolves a short <hostname-prefix>-<ip-suffix> id (e.g. v22-62) against
# `tailscale status`'s peer list, for typing a memorable id instead of a
# full IP/hostname. Source, don't execute. Assumes print.sh is in scope.

# Prints each peer's "hostname (ip)" as one comma-separated hint line.
suggest_tailscale_peers() {
    local status="$1"
    local line hostname ip
    local suggestions=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ip="$(awk '{print $1}' <<< "$line")"
        hostname="$(awk '{print $2}' <<< "$line")"
        suggestions+=("$hostname ($ip)")
    done <<< "$status"
    local joined
    joined="$(printf '%s, ' "${suggestions[@]}")"
    print_hint "${joined%, }"
}

# Prints (stdout) the one tailnet peer's IP matching $1 — tried first as
# <hostname-prefix>-<ip-suffix> (e.g. v22-62: hostname starts with "v22",
# IP ends with "62"), then, if that finds nothing, as a plain substring
# anywhere in the hostname (e.g. netcup, vps, or a hyphenated hostname
# like netcup-vps). Refuses on zero or multiple matches.
resolve_tailscale_peer() {
    local id="$1"
    local status
    status="$(tailscale status)"
    if [ -z "$status" ]; then
        print_error "'tailscale status' returned nothing — is tailscale up?"
        return 1
    fi

    local matches=""
    if [[ "$id" == *-* ]]; then
        local prefix="${id%%-*}" suffix="${id#*-}"
        matches="$(awk -v p="${prefix,,}" -v s="$suffix" \
            'tolower($2) ~ "^"p && $1 ~ s"$" {print}' <<< "$status")"
    fi
    if [ -z "$matches" ]; then
        matches="$(awk -v needle="${id,,}" 'tolower($2) ~ needle {print}' <<< "$status")"
    fi

    local match_count=0
    [ -n "$matches" ] && match_count="$(wc -l <<< "$matches")"

    if [ "$match_count" -eq 0 ]; then
        print_error "No tailnet peer matches '$id'. Candidates:"
        suggest_tailscale_peers "$status"
        return 1
    fi
    if [ "$match_count" -gt 1 ]; then
        print_error "$match_count peers match '$id' — give a longer id. Candidates:"
        suggest_tailscale_peers "$matches"
        return 1
    fi

    awk '{print $1}' <<< "$matches"
}
