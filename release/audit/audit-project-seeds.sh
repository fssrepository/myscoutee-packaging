#!/usr/bin/env bash
# Execute the selected declarative product policies without embedding their data.
audit_project_seeds() {
  local seed="$1" project="$2" config row file policy variable source
  config="${project}/config/packaging/release"
  local -a bindings=()
  jq -e 'type == "array" and all(.[];
    (.file | type == "string" and test("^[A-Za-z][A-Za-z0-9_.-]*$"))
    and (.policy | type == "string" and test("^seed-audits/[A-Za-z][A-Za-z0-9_.-]*\\.jq$"))
    and (.optional | type == "boolean") and (.error | type == "string"))' \
    "${config}/seed-audits.json" >/dev/null || return 1
  while IFS= read -r row; do
    file="$(jq -r .file <<< "$row")"
    [[ -f "${seed}/${file}" || "$(jq -r .optional <<< "$row")" != true ]] || continue
    policy="$(jq -r .policy <<< "$row")"
    bindings=()
    while IFS=$'\t' read -r variable source; do
      [[ -n "$variable" ]] || continue
      bindings+=(--slurpfile "$variable" "${project}/${source}")
    done < <(jq -r '(.slurpFiles // {}) | to_entries[] | [.key,.value] | @tsv' <<< "$row")
    if ! jq -e "${bindings[@]}" -f "${config}/${policy}" "${seed}/${file}" >/dev/null; then
      jq -r .error <<< "$row" >&2
      return 1
    fi
  done < <(jq -c '.[]' "${config}/seed-audits.json")
}
