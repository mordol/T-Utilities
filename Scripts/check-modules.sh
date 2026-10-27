#!/bin/bash
# Static checks of the module rules in Docs/MODULES.md. Run by `task check`, `task test` and Scripts/release.sh.
# A line that must break a rule carries `// module-rules: allow <reason>` on the same line or the line above;
# every such exception is listed in Docs/MODULES.md.
set -uo pipefail
cd "$(dirname "$0")/.."

failures=0
fail() { echo "✘ $*"; failures=$((failures + 1)); }

# Prints file:line:text of matches in module sources that have no allow marker on the line or the line above.
unmarked() { # pattern, files...
    local pattern=$1; shift
    PATTERN=$pattern awk '
        BEGIN { pattern = ENVIRON["PATTERN"] }
        FNR == 1 { previous = "" }
        $0 ~ pattern && $0 !~ /module-rules: allow/ && previous !~ /module-rules: allow/ { print FILENAME ":" FNR ": " $0 }
        { previous = $0 }
    ' "$@" || echo "check script error: awk failed for $pattern"
}

modules=()
for dir in Packages/Mod*/; do modules+=("$(basename "$dir")"); done
ids=()

for module in "${modules[@]}"; do
    dir=Packages/$module
    sources=$(find "$dir/Sources" -name '*.swift')
    [[ -n $sources ]] || { fail "$module: no sources"; continue; }

    # 1. Independence: a module depends on TUCore/TUUI/vendored or external code, never on another module.
    while IFS= read -r hit; do fail "depends on another module: $dir/Package.swift:$hit"; done \
        < <(grep -nE '\.package\(path: *"\.\./Mod' "$dir/Package.swift")
    own_targets=$(grep -oE '\.target\(name: *"[A-Za-z]+"' "$dir/Package.swift" | sed -E 's/.*"(.*)"/\1/')
    while IFS= read -r hit; do
        imported=$(sed -E 's/.*import +([A-Za-z]+).*/\1/' <<<"${hit#*: }")
        grep -qx "$imported" <<<"$own_targets" || fail "imports another module: $hit"
    done < <(grep -nE '^ *(@testable )?import +Mod[A-Z]' $sources /dev/null)

    # 2. Settings only through ModuleSettings (`module.<id>.*`); no other defaults or preference domains.
    while IFS= read -r hit; do fail "settings outside ModuleSettings: $hit"; done \
        < <(unmarked 'UserDefaults\.standard|UserDefaults *= *\.standard|UserDefaults\(suiteName|@AppStorage|CFPreferencesSet' $sources)

    # 3. No static mutable state (it outlives the instance and breaks "disabled = freed").
    while IFS= read -r hit; do fail "static mutable state: $hit"; done \
        < <(unmarked 'static var [^{]*=|nonisolated\(unsafe\) +(static|var)' $sources)

    # 4. Event taps only through SupervisedEventTap (an unsupervised tap can stall input system-wide).
    while IFS= read -r hit; do fail "raw event tap, use SupervisedEventTap: $hit"; done \
        < <(unmarked 'CGEvent\.tapCreate|CGEventTapCreate' $sources)

    # 5. The contract test runs in the module's tests.
    grep -rqs 'ModuleContract.violations(of:' "$dir/Tests" || fail "$module: missing ModuleContractTests (see Docs/MODULES.md)"

    # 6. Registered in the app: project.yml package + target dependency, AppModules.swift import.
    grep -qE "^  $module:$" project.yml || fail "$module: not under packages: in project.yml"
    grep -qE "^      - package: $module$" project.yml || fail "$module: not a T-Utilities dependency in project.yml"
    grep -qE "^import $module$" App/Sources/AppModules.swift || fail "$module: not imported in App/Sources/AppModules.swift"

    id=$(grep -hA1 'ModuleDescriptor(' $sources | grep -oE 'id: *"[^"]+"' | head -1 | sed -E 's/.*"(.*)"/\1/')
    if [[ -z $id ]]; then
        fail "$module: no ModuleDescriptor id found"
    else
        ids+=("$id")
        # 7. Hotkey names are namespaced by the module id (their storage keys are global).
        while IFS= read -r hit; do fail "hotkey name must start with \"$id.\": $hit"; done \
            < <(grep -nE 'KeyboardShortcuts\.Name\("|= Self\("' $sources /dev/null | grep -vE "\"$id\.")
    fi
done

# 8. Module ids are unique.
dupes=$(printf '%s\n' "${ids[@]}" | sort | uniq -d)
[[ -z $dupes ]] || fail "duplicate module ids: $dupes"

# 9. The shell knows modules only through AppModules.swift.
while IFS= read -r hit; do fail "app shell imports a module outside AppModules.swift: $hit"; done \
    < <(grep -nE '^import +Mod[A-Z]' $(find App/Sources -name '*.swift') /dev/null | grep -v '^App/Sources/AppModules.swift:')

# 10. Shared packages never depend on modules.
while IFS= read -r hit; do fail "shared package depends on a module: $hit"; done \
    < <(grep -nE '\.package\(path: *"\.\./Mod|^ *import +Mod[A-Z]' Packages/TUCore/Package.swift Packages/TUUI/Package.swift \
        $(find Packages/TUCore/Sources Packages/TUUI/Sources -name '*.swift') /dev/null)

if (( failures > 0 )); then
    echo "module rules: $failures problem(s) — see Docs/MODULES.md"
    exit 1
fi
echo "module rules: OK (${#modules[@]} modules)"
