#!/bin/bash
# Fetches and matches public keys from github.com/<user>.keys. Source,
# don't execute. Assumes print.sh is already sourced.

fetch_github_keys() {
    local user="$1"
    curl -fsSL "https://github.com/${user}.keys"
}

# Prints the lines of $2 (one key per line) whose raw key data ends with
# $1, case-sensitively.
match_github_keys_exact() {
    local id="$1" keys="$2"
    local line key_data
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key_data="$(awk '{print $2}' <<< "$line")"
        [[ "$key_data" == *"$id" ]] && echo "$line"
    done <<< "$keys"
}

# Same, case-insensitively.
match_github_keys_ci() {
    local id="$1" keys="$2"
    local id_lc line key_data
    id_lc="${id,,}"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key_data="$(awk '{print $2}' <<< "$line")"
        [[ "${key_data,,}" == *"$id_lc" ]] && echo "$line"
    done <<< "$keys"
}

# Prints each key's trailing characters as one comma-separated hint line.
suggest_github_keys() {
    local keys="$1" tail_len="${2:-8}"
    local line key_data
    local suggestions=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key_data="$(awk '{print $2}' <<< "$line")"
        suggestions+=("...${key_data: -$tail_len}")
    done <<< "$keys"
    local joined
    joined="$(printf '%s, ' "${suggestions[@]}")"
    print_hint "${joined%, }"
}

# Prints (stdout) the one github.com/$1.keys key ending in $2. Refuses on
# zero or multiple matches.
select_github_key() {
    local user="$1" id="$2"
    if [ "${#id}" -lt 3 ]; then
        print_error "key id must be at least 3 characters"
        return 1
    fi

    local keys
    keys="$(fetch_github_keys "$user")"
    if [ -z "$keys" ]; then
        print_error "No keys found at github.com/${user}.keys"
        return 1
    fi

    local matches
    matches="$(match_github_keys_exact "$id" "$keys")"
    [ -z "$matches" ] && matches="$(match_github_keys_ci "$id" "$keys")"

    local match_count=0
    [ -n "$matches" ] && match_count="$(wc -l <<< "$matches")"

    if [ "$match_count" -eq 0 ]; then
        print_error "No key at github.com/${user}.keys ends with '$id'. Candidates:"
        suggest_github_keys "$keys"
        return 1
    fi
    if [ "$match_count" -gt 1 ]; then
        print_error "$match_count keys at github.com/${user}.keys end with '$id' — give a longer id. Candidates:"
        suggest_github_keys "$matches"
        return 1
    fi

    echo "$matches"
}
