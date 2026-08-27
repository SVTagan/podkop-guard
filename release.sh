#!/bin/sh

set -eu

REPO="${PODKOP_GUARD_REPO:-SVTagan/podkop-guard}"
BRANCH="${PODKOP_GUARD_RELEASE_BRANCH:-main}"
ASSUME_YES=0

if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
    ASSUME_YES=1
elif [ -n "${1:-}" ]; then
    printf 'Usage: %s [--yes]\n' "$0" >&2
    exit 2
fi

info() {
    printf '[INFO] %s\n' "$*"
}

fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

need gh
need awk
need sed
need grep
need mktemp
need sh

gh auth status -h github.com >/dev/null 2>&1 || \
    fail "GitHub CLI is not authenticated. Run: gh auth login"

permission="$(gh repo view "$REPO" --json viewerPermission --jq '.viewerPermission' 2>/dev/null || true)"
case "$permission" in
    ADMIN|MAINTAIN|WRITE) ;;
    *) fail "Authenticated account does not have write access to $REPO (viewerPermission=${permission:-unknown})." ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/podkop-guard-release.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

fetch_raw() {
    local path="$1" output="$2"
    gh api \
        -H 'Accept: application/vnd.github.raw+json' \
        "repos/${REPO}/contents/${path}?ref=${BRANCH}" > "$output" || \
        fail "Cannot fetch ${path} from ${REPO}@${BRANCH}."
}

info "Fetching release inputs from ${REPO}@${BRANCH}..."
fetch_raw podkop-guard "$TMP_DIR/podkop-guard"
fetch_raw install.sh "$TMP_DIR/install.sh"
fetch_raw uninstall.sh "$TMP_DIR/uninstall.sh"
fetch_raw podkop-guard.init "$TMP_DIR/podkop-guard.init"
fetch_raw README.md "$TMP_DIR/README.md"
fetch_raw README.en.md "$TMP_DIR/README.en.md"
fetch_raw CHANGELOG.md "$TMP_DIR/CHANGELOG.md"

VERSION="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$TMP_DIR/podkop-guard" | head -n 1)"
[ -n "$VERSION" ] || fail "Cannot determine VERSION from podkop-guard."
TAG="v${VERSION}"

info "Detected version: ${VERSION} (${TAG})"

# Cheap pre-release consistency/syntax checks. These do not replace the real
# OpenWrt tests, but they prevent publishing an obviously inconsistent tree.
sh -n "$TMP_DIR/podkop-guard" || fail "podkop-guard failed shell syntax check."
sh -n "$TMP_DIR/install.sh" || fail "install.sh failed shell syntax check."
sh -n "$TMP_DIR/uninstall.sh" || fail "uninstall.sh failed shell syntax check."
sh -n "$TMP_DIR/podkop-guard.init" || fail "podkop-guard.init failed shell syntax check."

grep -Fq "Текущая версия: **${VERSION}**" "$TMP_DIR/README.md" || \
    fail "README.md version does not match ${VERSION}."
grep -Fq "Current version: **${VERSION}**" "$TMP_DIR/README.en.md" || \
    fail "README.en.md version does not match ${VERSION}."
grep -Eq "^## ${VERSION}([[:space:]]|$)" "$TMP_DIR/CHANGELOG.md" || \
    fail "CHANGELOG.md has no section for ${VERSION}."

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    url="$(gh release view "$TAG" --repo "$REPO" --json url --jq '.url')"
    info "Release ${TAG} already exists: ${url}"
    exit 0
fi

if gh api "repos/${REPO}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
    fail "Tag ${TAG} already exists but no GitHub Release is attached to it. Check the tag manually before publishing."
fi

CHANGELOG_SECTION="$TMP_DIR/changelog-section.md"
awk -v v="$VERSION" '
    BEGIN { capture = 0 }
    {
        if (index($0, "## " v " ") == 1 || $0 == "## " v) {
            capture = 1
            next
        }
        if (capture && $0 ~ /^## /) {
            exit
        }
        if (capture) {
            print
        }
    }
' "$TMP_DIR/CHANGELOG.md" > "$CHANGELOG_SECTION"

[ -s "$CHANGELOG_SECTION" ] || fail "Could not extract CHANGELOG section for ${VERSION}."

NOTES="$TMP_DIR/release-notes.md"
{
    printf '# podkop-guard %s\n\n' "$TAG"

    if ! gh release list --repo "$REPO" --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null | grep -q .; then
        printf 'Первый публичный GitHub Release проекта `podkop-guard`.\n\n'
        printf 'Проект решает конкретную задачу отказоустойчивости Podkop: хранит проверенный Last Known Good snapshot Community Lists, восстанавливает sing-box cache перед запуском Podkop после reboot/power loss и обновляет LKG только после полного набора проверок.\n\n'
    fi

    if [ "$VERSION" = "0.2.2" ]; then
        printf 'Версия 0.2.2 проверена на реальном **Cudy TR3000 v1 / OpenWrt 24.10.5 / Podkop 0.7.21 / sing-box 1.12.22**. Проверены настоящий reboot/cold-start, offline cache validation, Local Subnet LKG, periodic worker, LuCI Custom Commands и повторная установка без изменения persistent LKG.\n\n'
    fi

    printf 'Использование проекта — на свой риск; перед установкой рекомендуется прочитать README и иметь доступ к роутеру для восстановления конфигурации.\n\n'
    printf '## Изменения\n\n'
    cat "$CHANGELOG_SECTION"
    printf '\n---\n\n'
    printf '[README](https://github.com/%s/blob/%s/README.md) · [English README](https://github.com/%s/blob/%s/README.en.md) · [CHANGELOG](https://github.com/%s/blob/%s/CHANGELOG.md)\n' \
        "$REPO" "$BRANCH" "$REPO" "$BRANCH" "$REPO" "$BRANCH"
} > "$NOTES"

printf '\n=== RELEASE PREVIEW ===\n'
printf 'Repository: %s\n' "$REPO"
printf 'Target:     %s\n' "$BRANCH"
printf 'Tag:        %s\n' "$TAG"
printf 'Title:      podkop-guard %s\n\n' "$TAG"
cat "$NOTES"
printf '\n'

if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Create GitHub Release %s from %s? [y/N] ' "$TAG" "$BRANCH"
    IFS= read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) info "Release cancelled."; exit 0 ;;
    esac
fi

info "Creating GitHub Release ${TAG}..."
gh release create "$TAG" \
    --repo "$REPO" \
    --target "$BRANCH" \
    --title "podkop-guard ${TAG}" \
    --notes-file "$NOTES"

url="$(gh release view "$TAG" --repo "$REPO" --json url --jq '.url')"
info "Release created: ${url}"
