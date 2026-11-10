#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Bitbucket Server -> GitHub Git LFS object migration (CLI)
# gh bbs2gh migrates Git history only; LFS objects stay on Bitbucket. This script
# finds LFS repositories and copies their LFS objects to the migrated GitHub repos.
#
# Detect:  ./3_lfs_migration.sh --detect [--csv repos.csv] [--parallel 10]
#   Writes: lfs-repos-<timestamp>.csv, lfs-detection-report-<timestamp>.csv
# Migrate: ./3_lfs_migration.sh [--lfs-csv lfs-repos.csv] [--migration-output repo_migration_output-<timestamp>.csv]
#                               [--max-concurrent 2] [--target-api-url https://api.github.com]
#   Writes: lfs-migration-output-<timestamp>.csv, lfs-migration-<project>-<repo>-<timestamp>.txt
#
# CSV columns required: project-key, project-name, repo, github_org, github_repo, gh_repo_visibility
#
# Env:
#   BBS_BASE_URL
#   Auth: BBS_PAT OR (BBS_AUTH_TYPE=Basic with BBS_USERNAME + BBS_PASSWORD)
#   BBS_DISABLE_SSL_VERIFY (optional)
#   GH_PAT or GH_TOKEN (migrate only; falls back to gh auth token)
#   TARGET_API_URL (optional, same as --target-api-url)
# Requires: curl, jq; git and git-lfs for migrate
# ------------------------------------------------------------------------------
set -euo pipefail

MODE="migrate"
CSV_PATH="repos.csv"
LFS_CSV="lfs-repos.csv"
MIGRATION_OUTPUT=""
PARALLEL=10
MAX_CONCURRENT=2
TARGET_API_URL="${TARGET_API_URL:-https://api.github.com}"

usage() {
  echo "Usage: $0 --detect [--csv repos.csv] [--parallel N]" >&2
  echo "       $0 [--lfs-csv lfs-repos.csv] [--migration-output file.csv] [--max-concurrent N] [--target-api-url URL]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --detect) MODE="detect"; shift;;
    --csv) CSV_PATH="${2:-}"; shift 2 || usage;;
    --lfs-csv) LFS_CSV="${2:-}"; shift 2 || usage;;
    --migration-output) MIGRATION_OUTPUT="${2:-}"; shift 2 || usage;;
    --parallel) PARALLEL="${2:-}"; shift 2 || usage;;
    --max-concurrent) MAX_CONCURRENT="${2:-}"; shift 2 || usage;;
    --target-api-url|--github-api-url) TARGET_API_URL="${2:-}"; shift 2 || usage;;
    *) usage;;
  esac
done

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RED='\033[0;31m'; C_NC='\033[0m'
log_info()    { echo -e "${C_BLUE}[INFO]${C_NC} $1"; }
log_success() { echo -e "${C_GREEN}[OK]${C_NC} $1"; }
log_warning() { echo -e "${C_YELLOW}[WARNING]${C_NC} $1"; }
log_error()   { echo -e "${C_RED}[ERROR]${C_NC} $1" >&2; }

if [[ ! "$PARALLEL" =~ ^[0-9]+$ ]] || (( PARALLEL < 1 )); then
  log_error "--parallel must be a positive integer."; exit 1
fi
if [[ ! "$MAX_CONCURRENT" =~ ^[0-9]+$ ]] || (( MAX_CONCURRENT < 1 || MAX_CONCURRENT > 10 )); then
  log_error "--max-concurrent must be an integer from 1 to 10."; exit 1
fi
command -v jq >/dev/null 2>&1 || { log_error "jq is required."; exit 1; }
command -v curl >/dev/null 2>&1 || { log_error "curl is required."; exit 1; }

if [[ -z "${BBS_BASE_URL:-}" ]]; then
  log_error "BBS_BASE_URL env var is required."; exit 1
fi
BASE_URL="${BBS_BASE_URL%/}"

if [[ -n "${BBS_PAT:-}" ]]; then
  BBS_AUTH="Authorization: Bearer ${BBS_PAT}"
elif [[ "${BBS_AUTH_TYPE:-}" == "Basic" && -n "${BBS_USERNAME:-}" && -n "${BBS_PASSWORD:-}" ]]; then
  BBS_AUTH="Authorization: Basic $(printf '%s:%s' "$BBS_USERNAME" "$BBS_PASSWORD" | base64 | tr -d '\n')"
else
  log_error "Provide BBS_PAT or BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD."; exit 1
fi

DISABLE_SSL_VERIFY=false
case "${BBS_DISABLE_SSL_VERIFY:-}" in
  [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1) DISABLE_SSL_VERIFY=true ;;
esac
CURL_OPTS=(-sS)
$DISABLE_SSL_VERIFY && CURL_OPTS+=(--insecure)

timestamp="$(date +'%Y%m%d-%H%M%S')"
SEP=$'\x1f'
REQUIRED_COLUMNS=(project-key project-name repo github_org github_repo gh_repo_visibility)
CSV_HEADER="project-key,project-name,repo,github_org,github_repo,gh_repo_visibility"
WORK_TMP="$(mktemp -d)"
trap 'rm -rf "$WORK_TMP"' EXIT

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

bbs_get() {
  local status
  status="$(curl "${CURL_OPTS[@]}" -o "$2" -w '%{http_code}' -H "$BBS_AUTH" "$1" 2>/dev/null || true)"
  printf '%s' "${status:-000}"
}

parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next
  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"
    if [[ "${char}" == '"' ]]; then
      if [[ "${in_quotes}" == true ]]; then
        if [[ "${next}" == '"' ]]; then
          field+='"'; ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "${char}" == ',' && "${in_quotes}" == false ]]; then
      fields+=("${field}")
      field=""
    else
      field+="${char}"
    fi
  done
  fields+=("${field}")
  printf '%s\n' "${fields[@]}"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

csv_field() {
  local v="$1"
  if [[ "$v" == *[,\"]* ]]; then
    v="${v//\"/\"\"}"
    printf '"%s"' "$v"
  else
    printf '%s' "$v"
  fi
}

csv_row() {
  local out="" v
  for v in "$@"; do out+="$(csv_field "$v"),"; done
  printf '%s\n' "${out%,}"
}

read_csv_rows() {
  local file="$1" header line idx name v row
  local -a fields=() F=()
  local -A col=()
  ROWS=()
  [[ -f "$file" ]] || { log_error "CSV not found: $file"; exit 1; }
  IFS= read -r header < "$file" || true
  header="${header%$'\r'}"
  header="${header#$'\xEF\xBB\xBF'}"
  mapfile -t fields < <(parse_csv_line "$header")
  for idx in "${!fields[@]}"; do
    name="$(trim "${fields[$idx]}")"
    name="${name#\"}"; name="${name%\"}"
    col["$name"]="$idx"
  done
  for name in "${REQUIRED_COLUMNS[@]}"; do
    [[ -n "${col[$name]:-}" ]] || { log_error "CSV ${file} is missing required column '${name}'."; exit 1; }
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:],\"]/}" ]] && continue
    mapfile -t F < <(parse_csv_line "$line")
    row=""
    for name in "${REQUIRED_COLUMNS[@]}"; do
      v="$(trim "${F[${col[$name]}]:-}")"
      row+="${v}${SEP}"
    done
    ROWS+=("${row%"$SEP"}")
  done < <(tail -n +2 "$file")
}

resolve_slug() {
  local pk="$1" value="$2" body status encP encV start=0 found="" next
  body="$(mktemp "${WORK_TMP}/tmp.XXXXXX")"
  encP="$(urlencode "$pk")"; encV="$(urlencode "$value")"
  status="$(bbs_get "${BASE_URL}/rest/api/1.0/projects/${encP}/repos/${encV}" "$body")"
  if [[ "$status" == "200" ]]; then
    found="$(jq -r '.slug // empty' < "$body" 2>/dev/null || true)"
  fi
  while [[ -z "$found" ]]; do
    status="$(bbs_get "${BASE_URL}/rest/api/1.0/projects/${encP}/repos?limit=100&start=${start}" "$body")"
    [[ "$status" == "200" ]] || break
    found="$(jq -r --arg n "$value" '[.values[]? | select(((.name // "") | ascii_downcase) == ($n | ascii_downcase)) | .slug][0] // empty' < "$body" 2>/dev/null || true)"
    [[ -n "$found" ]] && break
    [[ "$(jq -r '.isLastPage' < "$body" 2>/dev/null || true)" == "true" ]] && break
    next="$(jq -r '.nextPageStart // empty' < "$body" 2>/dev/null || true)"
    [[ -z "$next" ]] && break
    start="$next"
  done
  rm -f "$body"
  printf '%s' "$found"
}

preflight() {
  local body status
  body="$(mktemp "${WORK_TMP}/tmp.XXXXXX")"
  status="$(bbs_get "${BASE_URL}/rest/api/1.0/projects?limit=1" "$body")"
  rm -f "$body"
  if [[ "$status" != "200" ]]; then
    case "$status" in
      401|403) log_error "Bitbucket auth failed (HTTP ${status}). Verify BBS_PAT / credentials and permissions." ;;
      000)     log_error "Could not reach ${BASE_URL} (network, DNS or TLS). Set BBS_DISABLE_SSL_VERIFY=true for self-signed certificates." ;;
      *)       log_error "Bitbucket preflight failed (HTTP ${status}) for ${BASE_URL}." ;;
    esac
    exit 1
  fi
}

detect_one() {
  local row="$1" out="$2" pk pn repo org ghr vis slug encP encS body status
  local enabled="unknown" attrs="false" is_lfs="false" note=""
  IFS="$SEP" read -r pk pn repo org ghr vis <<< "$row"
  slug="$(resolve_slug "$pk" "$repo")"
  if [[ -z "$slug" ]]; then
    is_lfs="error"; note="repository not found in Bitbucket"; slug="$repo"
  else
    body="$(mktemp "${WORK_TMP}/tmp.XXXXXX")"
    encP="$(urlencode "$pk")"; encS="$(urlencode "$slug")"
    status="$(bbs_get "${BASE_URL}/rest/git-lfs/admin/projects/${encP}/repos/${encS}/enabled" "$body")"
    case "$status" in
      200|204) enabled="true" ;;
      404)     enabled="false" ;;
      *)       note="LFS setting not readable (HTTP ${status})" ;;
    esac
    status="$(bbs_get "${BASE_URL}/rest/api/1.0/projects/${encP}/repos/${encS}/raw/.gitattributes" "$body")"
    if [[ "$status" == "200" ]]; then
      grep -Eq 'filter[[:space:]]*=[[:space:]]*lfs' "$body" && attrs="true"
    elif [[ "$status" != "404" ]]; then
      note="${note:+${note}; }.gitattributes not readable (HTTP ${status})"
    fi
    rm -f "$body"
    if [[ "$enabled" == "true" || "$attrs" == "true" ]]; then
      is_lfs="true"
    fi
  fi
  printf '%s\n' "${pk}${SEP}${pn}${SEP}${slug}${SEP}${org}${SEP}${ghr}${SEP}${vis}${SEP}${enabled}${SEP}${attrs}${SEP}${is_lfs}${SEP}${note}" > "$out"
}

run_detect() {
  read_csv_rows "$CSV_PATH"
  if (( ${#ROWS[@]} == 0 )); then
    log_error "No repositories found in ${CSV_PATH}."; exit 1
  fi
  preflight
  log_info "Checking ${#ROWS[@]} repositories for Git LFS (${PARALLEL} in parallel)..."
  local started=$SECONDS running=0 i
  for i in "${!ROWS[@]}"; do
    if (( running >= PARALLEL )); then
      wait -n || true
      running=$(( running - 1 ))
    fi
    detect_one "${ROWS[$i]}" "${WORK_TMP}/detect-$(printf '%06d' "$i")" &
    running=$(( running + 1 ))
  done
  wait || true

  local lfs_csv="lfs-repos-${timestamp}.csv" report="lfs-detection-report-${timestamp}.csv"
  local pk pn repo org ghr vis enabled attrs is_lfs note f lfs_count=0 err_count=0
  echo "$CSV_HEADER" > "$lfs_csv"
  echo "project-key,repo,github_org,github_repo,lfs_enabled,gitattributes_lfs,is_lfs_repo,notes" > "$report"
  for i in "${!ROWS[@]}"; do
    f="${WORK_TMP}/detect-$(printf '%06d' "$i")"
    if [[ -s "$f" ]]; then
      IFS="$SEP" read -r pk pn repo org ghr vis enabled attrs is_lfs note < "$f"
    else
      IFS="$SEP" read -r pk pn repo org ghr vis <<< "${ROWS[$i]}"
      enabled="unknown"; attrs="unknown"; is_lfs="error"; note="check did not complete"
    fi
    csv_row "$pk" "$repo" "$org" "$ghr" "$enabled" "$attrs" "$is_lfs" "$note" >> "$report"
    case "$is_lfs" in
      true)
        csv_row "$pk" "$pn" "$repo" "$org" "$ghr" "$vis" >> "$lfs_csv"
        lfs_count=$(( lfs_count + 1 ))
        log_warning "${pk}/${repo}: Git LFS repository (LFS enabled: ${enabled}, .gitattributes: ${attrs})"
        ;;
      error)
        err_count=$(( err_count + 1 ))
        log_error "${pk}/${repo}: ${note}"
        ;;
      *)
        log_success "${pk}/${repo}: no Git LFS${note:+ (${note})}"
        ;;
    esac
  done

  echo ""
  echo "[SUMMARY] Checked: ${#ROWS[@]} / LFS repos: ${lfs_count} / Errors: ${err_count} / Time: $(( SECONDS - started ))s"
  log_info "LFS repo list: ${lfs_csv}"
  log_info "Detection report: ${report}"
  if (( err_count > 0 )); then
    echo "::warning::${err_count} repository(ies) could not be checked for Git LFS. See ${report}."
  fi
  exit 0
}

derive_gh_host() {
  local host
  host="$(printf '%s' "$TARGET_API_URL" | sed -E 's#^https?://##; s#/.*$##')"
  printf '%s' "${host#api.}"
}

migrate_one() {
  local row="$1" log_file="$2" res="$3" pk pn repo org ghr vis slug encP encS work mir objects
  IFS="$SEP" read -r pk pn repo org ghr vis <<< "$row"
  {
    printf '[%s] [START] LFS objects: %s/%s -> %s/%s\n' "$(date)" "$pk" "$repo" "$org" "$ghr"
    slug="$(resolve_slug "$pk" "$repo")"
    if [[ -z "$slug" ]]; then
      printf '[%s] [ERROR] No repository in %s matches the name or slug %s\n' "$(date)" "$pk" "$repo"
      printf 'Failure%s0\n' "$SEP" > "$res"
      return 0
    fi
    encP="$(urlencode "$pk")"; encS="$(urlencode "$slug")"
    work="$(mktemp -d "${WORK_TMP}/work.XXXXXX")"
    mir="${work}/repo.git"

    printf '[%s] [STEP] Cloning mirror from Bitbucket\n' "$(date)"
    if ! git clone --mirror --quiet "${BASE_URL}/scm/${encP}/${encS}.git" "$mir"; then
      printf '[%s] [FAILED] Could not clone %s/%s from Bitbucket\n' "$(date)" "$pk" "$slug"
      rm -rf "$work"; printf 'Failure%s0\n' "$SEP" > "$res"; return 0
    fi

    printf '[%s] [STEP] Fetching all LFS objects from Bitbucket\n' "$(date)"
    if ! git -C "$mir" lfs fetch --all origin; then
      printf '[%s] [FAILED] git lfs fetch --all failed (objects missing on Bitbucket or access denied)\n' "$(date)"
      rm -rf "$work"; printf 'Failure%s0\n' "$SEP" > "$res"; return 0
    fi

    objects="$(find "${mir}/lfs/objects" -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '[%s] [INFO] LFS objects fetched: %s\n' "$(date)" "$objects"
    if [[ "$objects" == "0" ]]; then
      printf '[%s] [SUCCESS] No LFS objects to copy\n' "$(date)"
      rm -rf "$work"; printf 'Success%s0\n' "$SEP" > "$res"; return 0
    fi

    printf '[%s] [STEP] Pushing LFS objects to %s/%s/%s\n' "$(date)" "$GH_HOST" "$org" "$ghr"
    git -C "$mir" remote add github "https://${GH_HOST}/${org}/${ghr}.git"
    if ! git -C "$mir" lfs push --all github; then
      printf '[%s] [FAILED] git lfs push --all failed (check the GitHub repo exists and GH_PAT can write to it)\n' "$(date)"
      rm -rf "$work"; printf 'Failure%s%s\n' "$SEP" "$objects" > "$res"; return 0
    fi

    printf '[%s] [SUCCESS] Copied %s LFS object(s): %s/%s -> %s/%s\n' "$(date)" "$objects" "$pk" "$slug" "$org" "$ghr"
    rm -rf "$work"
    printf 'Success%s%s\n' "$SEP" "$objects" > "$res"
  } >> "$log_file" 2>&1
}

run_migrate() {
  command -v git >/dev/null 2>&1 || { log_error "git is required."; exit 1; }
  git lfs version >/dev/null 2>&1 || { log_error "git-lfs is required (https://git-lfs.com)."; exit 1; }

  GH_HOST="$(derive_gh_host)"
  local token="${GH_PAT:-${GH_TOKEN:-}}"
  if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token --hostname "$GH_HOST" 2>/dev/null || true)"
  fi
  [[ -n "$token" ]] || { log_error "Set GH_PAT (or GH_TOKEN, or run gh auth login)."; exit 1; }
  local gh_auth
  gh_auth="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"

  read_csv_rows "$LFS_CSV"
  local -a lfs_rows=("${ROWS[@]}")
  local out_csv="lfs-migration-output-${timestamp}.csv"
  echo "${CSV_HEADER},LFS_Status,LFS_Objects,Log_File" > "$out_csv"
  if (( ${#lfs_rows[@]} == 0 )); then
    log_warning "${LFS_CSV} lists no repositories. Run with --detect first, or add rows to it."
    log_info "Wrote ${out_csv}"
    exit 0
  fi

  local -A mig_status=()
  if [[ -n "$MIGRATION_OUTPUT" ]]; then
    [[ -f "$MIGRATION_OUTPUT" ]] || { log_error "Migration output not found: ${MIGRATION_OUTPUT}"; exit 1; }
    local mline mheader idx name
    local -a mfields=() MF=()
    local -A mcol=()
    IFS= read -r mheader < "$MIGRATION_OUTPUT" || true
    mapfile -t mfields < <(parse_csv_line "${mheader%$'\r'}")
    for idx in "${!mfields[@]}"; do
      name="$(trim "${mfields[$idx]}")"; name="${name#\"}"; name="${name%\"}"
      mcol["$name"]="$idx"
    done
    for name in github_org github_repo Migration_Status; do
      [[ -n "${mcol[$name]:-}" ]] || { log_error "${MIGRATION_OUTPUT} is missing column '${name}'."; exit 1; }
    done
    while IFS= read -r mline || [[ -n "$mline" ]]; do
      mline="${mline%$'\r'}"
      [[ -z "${mline//[[:space:],\"]/}" ]] && continue
      mapfile -t MF < <(parse_csv_line "$mline")
      mig_status["${MF[${mcol[github_org]}]:-}/${MF[${mcol[github_repo]}]:-}"]="${MF[${mcol[Migration_Status]}]:-}"
    done < <(tail -n +2 "$MIGRATION_OUTPUT")
  fi

  local cfg=0
  export GIT_TERMINAL_PROMPT=0
  export "GIT_CONFIG_KEY_${cfg}=http.${BASE_URL}/.extraHeader" "GIT_CONFIG_VALUE_${cfg}=${BBS_AUTH}"; cfg=$(( cfg + 1 ))
  export "GIT_CONFIG_KEY_${cfg}=http.https://${GH_HOST}/.extraHeader" "GIT_CONFIG_VALUE_${cfg}=${gh_auth}"; cfg=$(( cfg + 1 ))
  export "GIT_CONFIG_KEY_${cfg}=lfs.locksverify" "GIT_CONFIG_VALUE_${cfg}=false"; cfg=$(( cfg + 1 ))
  if $DISABLE_SSL_VERIFY; then
    export "GIT_CONFIG_KEY_${cfg}=http.${BASE_URL}/.sslVerify" "GIT_CONFIG_VALUE_${cfg}=false"; cfg=$(( cfg + 1 ))
  fi
  export GIT_CONFIG_COUNT="$cfg"

  preflight

  local -a statuses=() logs=() todo=()
  local i pk pn repo org ghr vis status safe
  for i in "${!lfs_rows[@]}"; do
    IFS="$SEP" read -r pk pn repo org ghr vis <<< "${lfs_rows[$i]}"
    safe="$(printf '%s-%s' "$pk" "$repo" | tr -c 'A-Za-z0-9._-' '_')"
    logs[$i]="lfs-migration-${safe}-${timestamp}.txt"
    if [[ -n "$MIGRATION_OUTPUT" ]]; then
      status="${mig_status["${org}/${ghr}"]:-}"
      if [[ "$status" != "Success" ]]; then
        statuses[$i]="Skipped - Not Migrated"
        log_warning "Skipping ${pk}/${repo} -> ${org}/${ghr}: migration status is '${status:-not in migration output}'."
        continue
      fi
    fi
    todo+=("$i")
  done

  log_info "Copying LFS objects for ${#todo[@]} repositories (${MAX_CONCURRENT} in parallel) to ${GH_HOST}..."
  local running=0
  for i in "${todo[@]}"; do
    if (( running >= MAX_CONCURRENT )); then
      wait -n || true
      running=$(( running - 1 ))
    fi
    IFS="$SEP" read -r pk pn repo org ghr vis <<< "${lfs_rows[$i]}"
    log_info "Started: ${pk}/${repo} -> ${org}/${ghr} (log: ${logs[$i]})"
    migrate_one "${lfs_rows[$i]}" "${logs[$i]}" "${WORK_TMP}/result-${i}" &
    running=$(( running + 1 ))
  done
  wait || true

  local objects ok=0 failed=0 skipped=0 res log
  for i in "${!lfs_rows[@]}"; do
    IFS="$SEP" read -r pk pn repo org ghr vis <<< "${lfs_rows[$i]}"
    objects=""
    log="${logs[$i]}"
    if [[ -n "${statuses[$i]:-}" ]]; then
      status="${statuses[$i]}"; skipped=$(( skipped + 1 )); log=""
    else
      res="${WORK_TMP}/result-${i}"
      if [[ -s "$res" ]]; then
        IFS="$SEP" read -r status objects < "$res"
      else
        status="Failure"; objects="0"
      fi
      if [[ "$status" == "Success" ]]; then
        ok=$(( ok + 1 )); log_success "${pk}/${repo} -> ${org}/${ghr}: ${objects} LFS object(s)"
      else
        failed=$(( failed + 1 )); log_error "${pk}/${repo} -> ${org}/${ghr}: failed (see ${logs[$i]})"
      fi
    fi
    csv_row "$pk" "$pn" "$repo" "$org" "$ghr" "$vis" "$status" "$objects" "$log" >> "$out_csv"
  done

  echo ""
  echo "[SUMMARY] LFS repos: ${#lfs_rows[@]} / Copied: ${ok} / Failed: ${failed} / Skipped (not migrated): ${skipped}"
  log_info "Wrote LFS migration results: ${out_csv}"
  if (( failed > 0 )); then
    echo "::error::Git LFS migration failed for ${failed} repository(ies)."
    exit 1
  fi
  exit 0
}

if [[ "$MODE" == "detect" ]]; then
  run_detect
else
  run_migrate
fi
