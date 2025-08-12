#!/bin/bash

# README for this script
# This script is used for updating Git submodules to a specific tag and optionally committing those changes.
# It reads a list of submodule URLs from an external file, checks each submodule, updates it to a specified tag,
# and then commits the change if the user agrees.

# Usage:
# 1. Create a file (default is 'submodules.md') and list each submodule URL on a new line.
# 2. Run this script. It will read the submodule URLs from the file.
# 3. For each submodule, the script will:
#    - Check if the submodule directory exists. If not, it will prompt to add the submodule.
#    - Fetch all tags from the remote repository.
#    - Prompt the user to select a tag for checkout (default is the latest tag).
#    - Checkout the specified tag.
#    - Prompt the user to commit the change. If agreed, it will commit the change.
# 4. After processing all submodules, the script ends with a message indicating the completion.

# Important:
# - Ensure you have the necessary permissions to modify the submodules and push changes.
# - Verify the submodule URLs in your file are correct and accessible.

#!/usr/bin/env bash
set -euo pipefail

# update-submodules.sh
# - Reads entries (URL or path) from submodules.md (or a file passed as argv[1])
# - For each submodule, ensures it's added/initialized, force-refreshes tags
#   (including moved/deleted tags), suggests the latest version tag (semver),
#   checks out in detached HEAD, and optionally commits the pointer in the superproject.
#
# Key fixes vs naive scripts:
# 1) Resolve path from .gitmodules when given a URL (exact mapping), avoid basename pitfalls.
# 2) Force/prune tags on fetch to correctly update moved/deleted tags.
# 3) Pick "latest" tag by version order, not by commit date.
# 4) Read all user prompts from /dev/tty, so file-backed while-read loops don't eat the next line.

######################################
# Config
######################################
SUBMODULES_FILE="${1:-submodules.md}"

######################################
# Utils
######################################
msg()  { printf "\n[INFO] %s\n"  "$*"; }
warn() { printf "\n[WARN] %s\n"  "$*" >&2; }
err()  { printf "\n[ERROR] %s\n" "$*" >&2; }

is_url() {
  local s="${1:-}"
  [[ "$s" =~ ^(git@|https?://|ssh://|file://) ]]
}

# Prompt from TTY only. If no TTY (e.g., CI), use default.
# Usage: ask_tty VAR "Prompt text: " "default"
ask_tty() {
  local __var="$1" __prompt="$2" __default="${3-}" __ans=""
  if [[ -t 0 || -t 1 ]]; then
    # Read from the terminal even if stdin is a file being consumed by while-read
    read -r -p "$__prompt" __ans < /dev/tty || true
  fi
  if [[ -z "$__ans" && -n "$__default" ]]; then
    __ans="$__default"
  fi
  printf -v "$__var" '%s' "$__ans"
}

# Find submodule path from URL using .gitmodules exact match
path_from_url() {
  local url="$1"
  local section
  section=$(git config -f .gitmodules --get-regexp '^submodule\..*\.url$' 2>/dev/null \
            | awk -v u="$url" '$2==u {print $1}' | head -n1 || true)
  [[ -z "$section" ]] && return 1
  local path_key="${section%.url}.path"
  git config -f .gitmodules --get "$path_key"
}

# Check if a given path exists in .gitmodules
path_exists_in_gitmodules() {
  local path="$1"
  local section
  section=$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
            | awk -v p="$path" '$2==p {print $1}' | head -n1 || true)
  [[ -n "$section" ]]
}

# Decide submodule path from input:
# - If URL: try .gitmodules mapping first; if none, fallback to basename.
# - If path: use as-is.
resolve_submodule_path() {
  local input="$1"
  if is_url "$input"; then
    if p=$(path_from_url "$input"); then
      printf "%s" "$p"
      return 0
    fi
    basename "$input" .git
    return 0
  else
    printf "%s" "$input"
    return 0
  fi
}

# Add a new submodule (URL or path given)
add_new_submodule() {
  local url_or_path="$1"
  local path="$2"

  if is_url "$url_or_path"; then
    local ans=""
    ask_tty ans "Submodule '$path' does not exist. Add it now? (yes/NO): " ""
    if [[ "$ans" == "yes" ]]; then
      git submodule add "$url_or_path" "$path" || { err "Failed to add submodule: $path"; return 1; }
      msg "Submodule added: $path"
    else
      warn "Skipped adding: $path"
      return 1
    fi
  else
    # Path provided but not registered; ask for URL to add
    warn "Input looks like a path but it's not registered in .gitmodules: $path"
    local url2=""
    ask_tty url2 "Enter remote URL to add for this path (empty to cancel): " ""
    if [[ -z "$url2" ]]; then
      warn "Skipped adding: $path"
      return 1
    fi
    git submodule add "$url2" "$path" || { err "Failed to add submodule: $path"; return 1; }
    msg "Submodule added: $path"
  fi
}

# Get the latest tag by version order (semver-friendly)
latest_version_tag() {
  git tag -l --sort=-v:refname | head -n1
}

# Force-refresh tags/refs, handling moved/deleted tags
force_refresh_tags() {
  git fetch origin --tags --prune --prune-tags --force
}

# Update one submodule (URL or path)
update_submodule() {
  local input="$1"
  local path
  path=$(resolve_submodule_path "$input")

  if [[ -z "$path" ]]; then
    err "Failed to resolve submodule path (input: $input)"
    return 1
  fi

  # Ensure directory exists, add if necessary
  if [[ ! -d "$path" ]]; then
    add_new_submodule "$input" "$path" || return 0
  fi

  # Sync config for this path (in case URL/path changed)
  git submodule sync -- "$path" >/dev/null 2>&1 || true

  msg "Processing submodule: $path"

  # Enter submodule
  pushd "$path" >/dev/null || { err "Failed to enter: $path"; return 1; }

  # Ensure it's initialized
  if [[ ! -d ".git" ]]; then
    warn "Submodule not initialized. Running init: $path"
    popd >/dev/null
    git submodule update --init -- "$path"
    pushd "$path" >/dev/null
  fi

  # Refresh tags/refs
  force_refresh_tags

  # List available tags (ascending version order)
  echo
  echo "[Available tags in $path]"
  git tag -l --sort=v:refname || true

  # Pick default latest tag
  local latest_tag=""
  latest_tag=$(latest_version_tag || true)

  local target_tag=""
  if [[ -n "$latest_tag" ]]; then
    ask_tty target_tag "Select a tag to checkout (ENTER = ${latest_tag}): " "$latest_tag"
  else
    warn "No tags available. Will fallback to the default branch HEAD."
  fi

  # Checkout
  if [[ -n "$target_tag" ]]; then
    if ! git -c advice.detachedHead=false checkout --detach "$target_tag"; then
      err "Checkout failed: $target_tag ($path)"
      popd >/dev/null
      return 1
    fi
    msg "Checked out: $target_tag ($path)"
  else
    git fetch origin --prune
    local default_ref
    default_ref=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
    default_ref="${default_ref:-origin/HEAD}"
    if ! git -c advice.detachedHead=false checkout --detach "$default_ref"; then
      err "Checkout failed: $default_ref ($path)"
      popd >/dev/null
      return 1
    fi
    msg "Checked out: $default_ref ($path)"
  fi

  popd >/dev/null

  # Ask to commit pointer in superproject
  local commit_answer=""
  ask_tty commit_answer "Commit this change in the superproject? (ENTER=yes / no): " ""
  if [[ "$commit_answer" != "no" ]]; then
    git add -- "$path"
    if [[ -n "${target_tag:-}" ]]; then
      git commit -m "Update submodule ${path} to ${target_tag}" || warn "Nothing to commit for: $path"
    else
      git commit -m "Update submodule ${path} to latest default branch" || warn "Nothing to commit for: $path"
    fi
    msg "Committed: $path"
  else
    msg "Commit skipped: $path"
  fi
}

######################################
# Main
######################################
if [[ ! -f "$SUBMODULES_FILE" ]]; then
  err "Input file not found: $SUBMODULES_FILE"
  exit 1
fi

msg "Start: submodule list = $SUBMODULES_FILE"
git submodule sync --recursive >/dev/null 2>&1 || true

# Read file (ignore comments/blank lines)
while IFS= read -r line || [[ -n "$line" ]]; do
  # trim
  entry="${line#"${line%%[![:space:]]*}"}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  # skip blanks/comments
  [[ -z "$entry" || "$entry" =~ ^# ]] && continue

  # If a path is given but it's neither in .gitmodules nor a local dir, warn early
  if ! is_url "$entry"; then
    if ! path_exists_in_gitmodules "$entry" && [[ ! -d "$entry" ]]; then
      warn "Entry '$entry' (path) not found in .gitmodules or local FS. URL input is recommended."
    fi
  fi

  update_submodule "$entry"
done < "$SUBMODULES_FILE"

msg "All submodules processed."
echo "ToDo: git log"
echo "ToDo: git push origin"
