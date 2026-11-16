#!/bin/bash
# Keeps the String Catalogs in step with the code.
#
#   scripts/l10n.sh sync    update Sources/<Module>/Localizable.xcstrings from the code
#   scripts/l10n.sh check   fail if a sync would change anything (new, unused or conflicting keys)
#
# Building never writes the catalogs. Instead, `swift build` has the compiler emit one .stringsdata file
# per source file (every String(localized:) key with its comment), and `xcstringstool sync` merges those
# into the catalog: it adds new keys, keeps existing values, drops unused untranslated keys and marks
# unused translated ones stale.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=${1:-}
case "$mode" in sync|check) ;; *) echo "usage: $0 sync|check" >&2; exit 2 ;; esac

modules=(DownCore DownUI)

swift build --build-system swiftbuild -q >/dev/null

# The .stringsdata of one module's current source files.
#
# Each .stringsdata records the absolute path of the source file it came from ("source": "…"). A file is
# used only if that source still exists under Sources/<Module>/, so output left behind by a deleted file
# can't keep its keys alive. When several files record the same source (another architecture, an older
# build folder), only the newest is used. Two processes in all: one `ls -t`, one `grep`.
stringsdata_args() {
    local module=$1 found=0 files=() f line file source seen=$'\n'
    local -a roots=("$PWD/Sources/$module/" "$(pwd -P)/Sources/$module/")
    while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(find .build -type f -path "*/$module-t.build/*" -name '*.stringsdata' -print0)
    if [ ${#files[@]} -gt 0 ]; then
        while IFS= read -r line; do
            file=${line%%:\"source\"*}
            source=${line#*\"source\"}
            source=${source#*\"}
            source=${source%\"}
            source=${source//\\\//\/}    # JSON may escape "/" as "\/"
            case "$source" in "${roots[0]}"*|"${roots[1]}"*) ;; *) continue ;; esac
            [ -f "$source" ] || continue
            case "$seen" in *$'\n'"$source"$'\n'*) continue ;; esac
            seen+="$source"$'\n'
            printf '%s\0' --stringsdata "$file"
            found=1
        done < <(ls -t "${files[@]}" | tr '\n' '\0' | xargs -0 grep -H -o '"source" *: *"[^"]*"')
    fi
    if [ $found = 0 ]; then
        echo "error: no .stringsdata found for $module under .build (did the build layout change?)" >&2
        return 1
    fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/down-l10n.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
status=0

for module in "${modules[@]}"; do
    catalog="Sources/$module/Localizable.xcstrings"
    args=()
    while IFS= read -r -d '' a; do args+=("$a"); done < <(stringsdata_args "$module")
    [ ${#args[@]} -gt 0 ] || exit 1

    if [ "$mode" = sync ]; then
        xcrun xcstringstool sync "$catalog" "${args[@]}"
        continue
    fi

    # xcstringstool matches tables by file name, so the copy keeps the name Localizable.xcstrings.
    mkdir -p "$tmp/$module"
    cp "$catalog" "$tmp/$module/Localizable.xcstrings"
    log=$(xcrun xcstringstool sync "$tmp/$module/Localizable.xcstrings" "${args[@]}" 2>&1)
    if grep -E 'used with multiple (comments|values)' <<<"$log" >&2; then
        echo "$catalog: a key is used with different comments or values; share one string or give each meaning its own key." >&2
        status=1
    fi
    if ! diff -u "$catalog" "$tmp/$module/Localizable.xcstrings" >&2; then
        status=1
    fi
    if grep -q '"extractionState" : "stale"' "$catalog"; then
        echo "$catalog has stale entries (keys no longer used in code); remove them." >&2
        status=1
    fi
done

if [ $status != 0 ]; then
    echo "String Catalogs are out of date: run 'make l10n-sync' and review the diff." >&2
fi
exit $status
