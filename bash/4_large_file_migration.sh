#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Bitbucket Server -> GitHub migration of repositories with large files (CLI)
# gh bbs2gh rejects files >= 400 MiB. This script finds such repositories, converts
# their large files to Git LFS (git lfs migrate import - REWRITES HISTORY, commit SHAs
# change) and pushes them to GitHub directly, without gh bbs2gh.
#
# Detect:    ./4_large_file_migration.sh --detect [--csv repos.csv] [--threshold-mb 400] [--prefilter-mb 100] [--parallel 4]
#   Writes: large-file-repos-<timestamp>.csv, large-file-report-<timestamp>.csv,
#           repo-size-report-<timestamp>.csv (git-sizer style metrics per scanned repo)
# List only: ./4_large_file_migration.sh --list-only [--csv large-file-repos.csv]
#   Resolves repository names to slugs without scanning. Writes: large-file-repos-<timestamp>.csv
# Migrate:   ./4_large_file_migration.sh [--large-csv large-file-repos.csv] [--convert-above-mb 100]
#                                        [--max-concurrent 1] [--target-api-url https://api.github.com]
#   Writes: large-file-migration-output-<timestamp>.csv, large-file-migration-<project>-<repo>-<timestamp>.txt,
#           large-file-sha-map-<project>-<repo>-<timestamp>.csv (old commit SHA,new commit SHA)
#
# CSV columns required: project-key, project-name, repo, github_org, github_repo, gh_repo_visibility
#
# Env:
#   BBS_BASE_URL
#   Auth: BBS_PAT OR (BBS_AUTH_TYPE=Basic with BBS_USERNAME + BBS_PASSWORD)
#   BBS_DISABLE_SSL_VERIFY (optional)
#   GH_PAT or GH_TOKEN (migrate only; falls back to gh auth token)
#   TARGET_API_URL (optional, same as --target-api-url)
# Requires: curl, jq, git (2.31+); git-lfs for migrate
# ------------------------------------------------------------------------------
set -euo pipefail

MODE="migrate"
CSV_PATH=""
LARGE_CSV="large-file-repos.csv"
THRESHOLD_MB=400
PREFILTER_MB=""
CONVERT_ABOVE_MB=100
PARALLEL=4
MAX_CONCURRENT=1
TARGET_API_URL="${TARGET_API_URL:-https://api.github.com}"

usage() {
  echo "Usage: $0 --detect [--csv repos.csv] [--threshold-mb N] [--prefilter-mb N] [--parallel N]" >&2
  echo "       $0 --list-only [--csv large-file-repos.csv]" >&2
  echo "       $0 [--large-csv large-file-repos.csv] [--convert-above-mb N] [--max-concurrent N] [--target-api-url URL]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --detect) MODE="detect"; shift;;
    --list-only) MODE="list"; shift;;
    --csv) CSV_PATH="${2:-}"; shift 2 || usage;;
    --large-csv) LARGE_CSV="${2:-}"; shift 2 || usage;;
    --threshold-mb) THRESHOLD_MB="${2:-}"; shift 2 || usage;;
    --prefilter-mb) PREFILTER_MB="${2:-}"; shift 2 || usage;;
    --convert-above-mb) CONVERT_ABOVE_MB="${2:-}"; shift 2 || usage;;
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

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
[[ -n "$PREFILTER_MB" ]] || PREFILTER_MB=$(( THRESHOLD_MB / 4 ))
for v in THRESHOLD_MB PREFILTER_MB CONVERT_ABOVE_MB PARALLEL MAX_CONCURRENT; do
  is_uint "${!v}" || { log_error "${v} must be a non-negative integer (got '${!v}')."; exit 1; }
done
(( THRESHOLD_MB >= 1 )) || { log_error "--threshold-mb must be at least 1."; exit 1; }
(( CONVERT_ABOVE_MB >= 1 && CONVERT_ABOVE_MB <= 100 )) || { log_error "--convert-above-mb must be from 1 to 100 (GitHub rejects files over 100 MB)."; exit 1; }
(( PARALLEL >= 1 )) || { log_error "--parallel must be at least 1."; exit 1; }
(( MAX_CONCURRENT >= 1 && MAX_CONCURRENT <= 10 )) || { log_error "--max-concurrent must be an integer from 1 to 10."; exit 1; }
command -v jq >/dev/null 2>&1 || { log_error "jq is required."; exit 1; }
command -v curl >/dev/null 2>&1 || { log_error "curl is required."; exit 1; }
command -v git >/dev/null 2>&1 || { log_error "git is required."; exit 1; }

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

set_git_config_env() {
  local cfg=0
  export GIT_TERMINAL_PROMPT=0
  export "GIT_CONFIG_KEY_${cfg}=http.${BASE_URL}/.extraHeader" "GIT_CONFIG_VALUE_${cfg}=${BBS_AUTH}"; cfg=$(( cfg + 1 ))
  export "GIT_CONFIG_KEY_${cfg}=lfs.locksverify" "GIT_CONFIG_VALUE_${cfg}=false"; cfg=$(( cfg + 1 ))
  if $DISABLE_SSL_VERIFY; then
    export "GIT_CONFIG_KEY_${cfg}=http.${BASE_URL}/.sslVerify" "GIT_CONFIG_VALUE_${cfg}=false"; cfg=$(( cfg + 1 ))
  fi
  if [[ -n "${GH_AUTH:-}" ]]; then
    export "GIT_CONFIG_KEY_${cfg}=http.https://${GH_HOST}/.extraHeader" "GIT_CONFIG_VALUE_${cfg}=${GH_AUTH}"; cfg=$(( cfg + 1 ))
  fi
  export GIT_CONFIG_COUNT="$cfg"
}

run_pool() {
  local limit="$1" fn="$2" running=0 i
  shift 2
  for i in "$@"; do
    if (( running >= limit )); then
      wait -n || true
      running=$(( running - 1 ))
    fi
    "$fn" "$i" &
    running=$(( running + 1 ))
  done
  wait || true
}

load_input_rows() {
  read_csv_rows "$1"
  if (( ${#ROWS[@]} == 0 )); then
    log_error "No repositories found in $1."; exit 1
  fi
  INPUT_ROWS=("${ROWS[@]}")
}

list_one() {
  local i="$1" pk pn repo org ghr vis slug
  IFS="$SEP" read -r pk pn repo org ghr vis <<< "${INPUT_ROWS[$i]}"
  slug="$(resolve_slug "$pk" "$repo")"
  printf '%s\n' "${slug}" > "${WORK_TMP}/list-${i}"
}

run_list() {
  load_input_rows "${CSV_PATH:-large-file-repos.csv}"
  preflight
  run_pool "$PARALLEL" list_one "${!INPUT_ROWS[@]}"
  local out="large-file-repos-${timestamp}.csv" i pk pn repo org ghr vis slug missing=0
  echo "$CSV_HEADER" > "$out"
  for i in "${!INPUT_ROWS[@]}"; do
    IFS="$SEP" read -r pk pn repo org ghr vis <<< "${INPUT_ROWS[$i]}"
    slug="$(cat "${WORK_TMP}/list-${i}" 2>/dev/null || true)"
    if [[ -z "$slug" ]]; then
      log_error "${pk}/${repo}: repository not found in Bitbucket - kept as written"
      slug="$repo"; missing=$(( missing + 1 ))
    fi
    csv_row "$pk" "$pn" "$slug" "$org" "$ghr" "$vis" >> "$out"
  done
  log_info "Large-file repo list: ${out} (${#INPUT_ROWS[@]} repo(s), ${missing} not found)"
  exit 0
}

int_mb() {
  local v="${1#>=}"
  v="${v%%.*}"
  printf '%s' "${v:-0}"
}

repo_metrics() {
  local bare="$1" work="$2" thr="$3" commits depth=0 d ref branches tags pack_kib
  GIT_NO_LAZY_FETCH=1 git -C "$bare" log --all --no-renames --raw --no-abbrev --format='C %H' > "${work}/log" 2>/dev/null || true
  commits="$(git -C "$bare" rev-list --all --count 2>/dev/null || echo 0)"
  while IFS= read -r ref; do
    d="$(git -C "$bare" rev-list --count "$ref" 2>/dev/null || echo 0)"
    (( d > depth )) && depth=$d
  done < <(git -C "$bare" for-each-ref --format='%(refname)' refs/heads refs/tags 2>/dev/null)
  branches="$(git -C "$bare" for-each-ref refs/heads 2>/dev/null | wc -l | tr -d ' ')"
  tags="$(git -C "$bare" for-each-ref refs/tags 2>/dev/null | wc -l | tr -d ' ')"
  pack_kib="$(git -C "$bare" count-objects -v 2>/dev/null | awk '$1 == "size-pack:" { print $2 }')"
  awk -v thr="$thr" -v thr_mb="$THRESHOLD_MB" -v sep="$SEP" \
      -v commits="$commits" -v depth="$depth" -v branches="$branches" -v tags="$tags" -v pack_kib="${pack_kib:-0}" '
    function mb(b) { return sprintf("%.2f", b / 1048576) }
    function flush() { if (cur != "" && csum > maxc) { maxc = csum; maxcid = cur; maxcge = cge } }
    FILENAME == ARGV[1] {
      if ($1 == "blob") { bsize[$2] = $3; blobs++; total += $3; if ($3 > 104857600) over100++; if ($3 >= thr) overthr++ }
      else if ($1 == "tree") trees++
      next
    }
    FILENAME == ARGV[2] {
      if (substr($0, 1, 1) == "?") { miss[substr($0, 2)] = 1; missing++; next }
      sp = index($0, " "); if (sp == 0) next
      oid = substr($0, 1, sp - 1); path = substr($0, sp + 1); if (path == "") next
      if (!(oid in pathof)) pathof[oid] = path
      if (length(path) > maxlen) maxlen = length(path)
      n = split(path, parts, "/"); if (n > maxdepth) maxdepth = n
      next
    }
    {
      if (substr($0, 1, 2) == "C ") { flush(); cur = substr($0, 3); csum = 0; cge = 0; next }
      if (substr($0, 1, 1) != ":") next
      split($0, t, "\t"); split(t[1], a, " "); oid = a[4]
      if (!(oid in pathof)) pathof[oid] = t[2]
      if (length(t[2]) > maxlen) maxlen = length(t[2])
      n = split(t[2], parts, "/"); if (n > maxdepth) maxdepth = n
      if (a[5] ~ /^[AMT]/) { if (oid in bsize) csum += bsize[oid]; else if (oid in miss) { csum += thr; cge = 1 } }
    }
    END {
      flush()
      for (o in bsize) if (bsize[o] > maxb) { maxb = bsize[o]; maxbid = o }
      if (missing > 0) {
        for (o in miss) { largest_id = o; break }
        largest = ">=" thr_mb; total_out = ">=" mb(total + missing * thr)
        overthr += missing; if (thr >= 104857600) over100 += missing
      } else {
        largest_id = maxbid; largest = (maxbid == "" ? "0" : mb(maxb)); total_out = mb(total)
      }
      lpath = (largest_id in pathof) ? pathof[largest_id] : largest_id
      print mb(pack_kib * 1024) sep commits sep depth sep branches sep tags sep trees + 0 sep blobs + missing sep total_out \
            sep largest sep lpath sep over100 + 0 sep overthr + 0 sep (maxcge ? ">=" : "") mb(maxc) sep maxcid \
            sep maxdepth + 0 sep maxlen + 0
    }
  ' "${work}/sizes" "${work}/objects" "${work}/log"
}

detect_one() {
  local i="$1" pk pn repo org ghr vis slug encP encS body status bytes size_mb="" result="false" note=""
  local work bare thr files_out="${WORK_TMP}/files-${i}" count=0
  IFS="$SEP" read -r pk pn repo org ghr vis <<< "${INPUT_ROWS[$i]}"
  : > "$files_out"
  slug="$(resolve_slug "$pk" "$repo")"
  if [[ -z "$slug" ]]; then
    result="error"; note="repository not found in Bitbucket"; slug="$repo"
  else
    encP="$(urlencode "$pk")"; encS="$(urlencode "$slug")"
    body="$(mktemp "${WORK_TMP}/tmp.XXXXXX")"
    status="$(bbs_get "${BASE_URL}/projects/${encP}/repos/${encS}/sizes" "$body")"
    if [[ "$status" == "200" ]]; then
      bytes="$(jq -r '.repository // empty' < "$body" 2>/dev/null || true)"
      is_uint "$bytes" && size_mb=$(( bytes / 1024 / 1024 ))
    fi
    rm -f "$body"
    if [[ -n "$size_mb" ]] && (( PREFILTER_MB > 0 && size_mb < PREFILTER_MB )); then
      note="repository size ${size_mb} MB is below the ${PREFILTER_MB} MB pre-filter - not cloned"
    else
      work="$(mktemp -d "${WORK_TMP}/scan.XXXXXX")"
      bare="${work}/repo.git"
      thr=$(( THRESHOLD_MB * 1024 * 1024 ))
      if ! git clone --bare --quiet --filter="blob:limit=${THRESHOLD_MB}m" \
           "${BASE_URL}/scm/${encP}/${encS}.git" "$bare" 2> "${work}/err"; then
        result="error"; note="clone failed: $(grep -v '^warning:' "${work}/err" | tail -n 1)"
      else
        GIT_NO_LAZY_FETCH=1 git -C "$bare" rev-list --objects --all --missing=print > "${work}/objects" 2>/dev/null || true
        { grep '^?' "${work}/objects" | cut -c2- | awk '{ print $1 "\t" }' || true; } > "${work}/large"
        { grep -v '^?' "${work}/objects" | cut -d' ' -f1 \
            | GIT_NO_LAZY_FETCH=1 git -C "$bare" cat-file --batch-check='%(objecttype) %(objectname) %(objectsize)' 2>/dev/null || true; } > "${work}/sizes"
        awk -v t="$thr" '$1 == "blob" && ($3 + 0) >= t { print $2 "\t" $3 }' "${work}/sizes" >> "${work}/large"
        repo_metrics "$bare" "$work" "$thr" > "${WORK_TMP}/metrics-${i}" || true
        count="$(wc -l < "${work}/large" | tr -d ' ')"
        if (( count > 0 )); then
          result="true"
          note="${count} file(s) >= ${THRESHOLD_MB} MB"
          GIT_NO_LAZY_FETCH=1 git -C "$bare" log --all --no-renames --raw --no-abbrev --format= 2>/dev/null \
            | awk -F'\t' -v pk="$pk" -v rs="$slug" -v thr="$THRESHOLD_MB" -v sep="$SEP" '
                NR == FNR { want[$1] = $2; next }
                { split($1, a, " "); oid = a[4]
                  if ((oid in want) && !(oid in seen)) {
                    seen[oid] = 1
                    size = (want[oid] == "" ? ">=" thr : int(want[oid] / 1048576))
                    print pk sep rs sep $2 sep size
                  } }
                END { for (o in want) if (!(o in seen)) print pk sep rs sep "(path not found: " o ")" sep (want[o] == "" ? ">=" thr : int(want[o] / 1048576)) }
              ' "${work}/large" - >> "$files_out" || true
        else
          note="no files >= ${THRESHOLD_MB} MB"
        fi
      fi
      rm -rf "$work"
    fi
  fi
  printf '%s\n' "${pk}${SEP}${pn}${SEP}${slug}${SEP}${org}${SEP}${ghr}${SEP}${vis}${SEP}${size_mb}${SEP}${result}${SEP}${count}${SEP}${note}" > "${WORK_TMP}/detect-${i}"
}

run_detect() {
  load_input_rows "${CSV_PATH:-repos.csv}"
  preflight
  set_git_config_env
  log_info "Scanning ${#INPUT_ROWS[@]} repositories for files >= ${THRESHOLD_MB} MB (${PARALLEL} in parallel; repos under ${PREFILTER_MB} MB are not cloned)..."
  local started=$SECONDS
  run_pool "$PARALLEL" detect_one "${!INPUT_ROWS[@]}"

  local list="large-file-repos-${timestamp}.csv" report="large-file-report-${timestamp}.csv" sizes="repo-size-report-${timestamp}.csv"
  local i f pk pn repo org ghr vis size_mb result count note found=0 errors=0 fpath fsize
  local clone_mb commits depth branches tags trees blobs blobs_mb largest_mb largest_path over100 overthr commit_mb commit_id path_depth path_len warnings
  echo "$CSV_HEADER" > "$list"
  echo "project-key,repo,github_org,github_repo,repo_size_mb,has_large_files,file_path,file_size_mb,notes" > "$report"
  echo "project-key,repo,github_org,github_repo,bitbucket_size_mb,clone_size_mb,commits,max_history_depth,branches,tags,trees,files,files_total_mb,largest_file_mb,largest_file_path,files_over_100mb,files_over_threshold,largest_commit_mb,largest_commit,max_path_depth,max_path_length,warnings,notes" > "$sizes"
  for i in "${!INPUT_ROWS[@]}"; do
    f="${WORK_TMP}/detect-${i}"
    if [[ -s "$f" ]]; then
      IFS="$SEP" read -r pk pn repo org ghr vis size_mb result count note < "$f"
    else
      IFS="$SEP" read -r pk pn repo org ghr vis <<< "${INPUT_ROWS[$i]}"
      size_mb=""; result="error"; count=0; note="scan did not complete"
    fi
    if [[ -s "${WORK_TMP}/metrics-${i}" ]]; then
      IFS="$SEP" read -r clone_mb commits depth branches tags trees blobs blobs_mb largest_mb largest_path over100 overthr commit_mb commit_id path_depth path_len < "${WORK_TMP}/metrics-${i}"
      warnings=""
      (( overthr > 0 )) && warnings+="${overthr} file(s) >= ${THRESHOLD_MB} MB (gh bbs2gh rejects files >= 400 MiB); "
      (( over100 > 0 )) && warnings+="${over100} file(s) > 100 MB (GitHub rejects pushes of files over 100 MB); "
      (( $(int_mb "$commit_mb") >= 2048 )) && warnings+="a commit adds ${commit_mb} MB (GitHub limit 2 GB per commit); "
      (( $(int_mb "$blobs_mb") >= 40960 || ${size_mb:-0} >= 40960 )) && warnings+="repository is about 40 GB or more (GitHub Enterprise Importer archive limit ~40 GiB); "
      csv_row "$pk" "$repo" "$org" "$ghr" "$size_mb" "$clone_mb" "$commits" "$depth" "$branches" "$tags" "$trees" "$blobs" "$blobs_mb" \
        "$largest_mb" "$largest_path" "$over100" "$overthr" "$commit_mb" "$commit_id" "$path_depth" "$path_len" "${warnings%; }" "" >> "$sizes"
      [[ -n "$warnings" && "$result" != "true" ]] && log_warning "${pk}/${repo}: ${warnings%; }"
    else
      csv_row "$pk" "$repo" "$org" "$ghr" "$size_mb" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "$note" >> "$sizes"
    fi
    case "$result" in
      true)
        found=$(( found + 1 ))
        csv_row "$pk" "$pn" "$repo" "$org" "$ghr" "$vis" >> "$list"
        log_warning "${pk}/${repo}: ${note}"
        while IFS="$SEP" read -r _ _ fpath fsize; do
          csv_row "$pk" "$repo" "$org" "$ghr" "$size_mb" "true" "$fpath" "$fsize" "" >> "$report"
          log_warning "  ${fpath} (${fsize} MB)"
        done < "${WORK_TMP}/files-${i}"
        ;;
      error)
        errors=$(( errors + 1 ))
        csv_row "$pk" "$repo" "$org" "$ghr" "$size_mb" "error" "" "" "$note" >> "$report"
        log_error "${pk}/${repo}: ${note}"
        ;;
      *)
        csv_row "$pk" "$repo" "$org" "$ghr" "$size_mb" "false" "" "" "$note" >> "$report"
        log_success "${pk}/${repo}: ${note}"
        ;;
    esac
  done

  echo ""
  echo "[SUMMARY] Checked: ${#INPUT_ROWS[@]} / Repos with large files: ${found} / Errors: ${errors} / Time: $(( SECONDS - started ))s"
  log_info "Large-file repo list: ${list}"
  log_info "Large-file report: ${report}"
  log_info "Repository size report: ${sizes}"
  if (( errors > 0 )); then
    echo "::warning::${errors} repository(ies) could not be scanned for large files. See ${report}."
  fi
  exit 0
}

derive_gh_host() {
  local host
  host="$(printf '%s' "$TARGET_API_URL" | sed -E 's#^https?://##; s#/.*$##')"
  printf '%s' "${host#api.}"
}

gh_api() {
  local method="$1" path="$2" out="$3" data="${4:-}" status
  local -a args=(-sS -o "$out" -w '%{http_code}' -X "$method"
    -H "Authorization: Bearer ${GH_TOKEN_VALUE}" -H "Accept: application/vnd.github+json")
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")
  status="$(curl "${args[@]}" "${TARGET_API_URL%/}${path}" 2>/dev/null || true)"
  printf '%s' "${status:-000}"
}

bbs_default_branch() {
  local encP="$1" encS="$2" body status branch=""
  body="$(mktemp "${WORK_TMP}/tmp.XXXXXX")"
  status="$(bbs_get "${BASE_URL}/rest/api/1.0/projects/${encP}/repos/${encS}/default-branch" "$body")"
  [[ "$status" == "200" ]] || status="$(bbs_get "${BASE_URL}/rest/api/1.0/projects/${encP}/repos/${encS}/branches/default" "$body")"
  [[ "$status" == "200" ]] && branch="$(jq -r '.displayId // empty' < "$body" 2>/dev/null || true)"
  rm -f "$body"
  printf '%s' "$branch"
}

migrate_one() {
  local i="$1" log_file="${LOGS[$1]}" map_file="${MAPS[$1]}" res="${WORK_TMP}/result-${1}"
  local pk pn repo org ghr vis slug encP encS work bare objects=0 default_branch status body payload
  IFS="$SEP" read -r pk pn repo org ghr vis <<< "${MIG_ROWS[$i]}"
  fail() { printf '[%s] [FAILED] %s\n' "$(date)" "$1"; [[ -n "${work:-}" ]] && rm -rf "$work"; printf 'Failure%s%s%s\n' "$SEP" "$objects" "$SEP" > "$res"; }
  {
    printf '[%s] [START] Large-file migration: %s/%s -> %s/%s (%s)\n' "$(date)" "$pk" "$repo" "$org" "$ghr" "${vis:-private}"
    slug="$(resolve_slug "$pk" "$repo")"
    if [[ -z "$slug" ]]; then fail "No repository in ${pk} matches the name or slug ${repo}"; return 0; fi
    encP="$(urlencode "$pk")"; encS="$(urlencode "$slug")"
    default_branch="$(bbs_default_branch "$encP" "$encS")"
    work="$(mktemp -d "${WORK_TMP}/work.XXXXXX")"
    bare="${work}/repo.git"
    body="${work}/api.json"

    printf '[%s] [STEP] Cloning from Bitbucket (branches and tags)\n' "$(date)"
    if ! git clone --bare --quiet "${BASE_URL}/scm/${encP}/${encS}.git" "$bare"; then
      fail "Could not clone ${pk}/${slug} from Bitbucket"; return 0
    fi

    printf '[%s] [STEP] Fetching existing LFS objects from Bitbucket (if any)\n' "$(date)"
    if ! git -C "$bare" lfs fetch --all origin; then
      fail "git lfs fetch --all failed (existing LFS objects missing on Bitbucket or access denied)"; return 0
    fi

    printf '[%s] [STEP] Converting files above %s MB to Git LFS (history is rewritten)\n' "$(date)" "$CONVERT_ABOVE_MB"
    if ! git -C "$bare" lfs migrate import --everything --above="${CONVERT_ABOVE_MB}MB" --yes --object-map="${PWD}/${map_file}"; then
      fail "git lfs migrate import failed"; return 0
    fi
    [[ -f "$map_file" ]] || : > "$map_file"
    objects="$(find "${bare}/lfs/objects" -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '[%s] [INFO] LFS objects: %s / rewritten commits: %s (map: %s)\n' "$(date)" "$objects" "$(wc -l < "$map_file" | tr -d ' ')" "$map_file"
    if [[ -n "$(find "${bare}/lfs/objects" -type f -size +2147483648c 2>/dev/null | head -n 1)" ]]; then
      printf '[%s] [WARNING] Some LFS objects exceed 2 GB. GitHub rejects LFS files above its plan limit (2-5 GB).\n' "$(date)"
    fi

    printf '[%s] [STEP] Creating GitHub repository %s/%s\n' "$(date)" "$org" "$ghr"
    payload="$(jq -nc --arg n "$ghr" --arg v "${vis:-private}" '{name: $n, visibility: $v, auto_init: false}')"
    status="$(gh_api POST "/orgs/$(urlencode "$org")/repos" "$body" "$payload")"
    case "$status" in
      201) printf '[%s] [INFO] Repository created\n' "$(date)" ;;
      422)
        status="$(gh_api GET "/repos/$(urlencode "$org")/$(urlencode "$ghr")" "$body")"
        if [[ "$status" != "200" ]]; then fail "Could not create ${org}/${ghr}: $(head -c 300 "$body")"; return 0; fi
        printf '[%s] [WARNING] Repository already exists - pushing into it (non-force; diverging history will be rejected)\n' "$(date)"
        ;;
      *) fail "Could not create ${org}/${ghr} (HTTP ${status}): $(head -c 300 "$body")"; return 0 ;;
    esac

    git -C "$bare" remote add github "https://${GH_HOST}/${org}/${ghr}.git"
    printf '[%s] [STEP] Pushing LFS objects\n' "$(date)"
    if ! git -C "$bare" lfs push --all github; then
      fail "git lfs push --all failed (LFS file above the GitHub plan limit, or GH_PAT cannot write)"; return 0
    fi
    printf '[%s] [STEP] Pushing branches and tags\n' "$(date)"
    if ! git -C "$bare" push github 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'; then
      fail "git push failed (history diverges from an existing GitHub repo, or the push exceeds GitHub's 2 GB push limit)"; return 0
    fi

    if [[ -n "$default_branch" ]] && git -C "$bare" show-ref --verify --quiet "refs/heads/${default_branch}"; then
      status="$(gh_api PATCH "/repos/$(urlencode "$org")/$(urlencode "$ghr")" "$body" "$(jq -nc --arg b "$default_branch" '{default_branch: $b}')")"
      if [[ "$status" == "200" ]]; then
        printf '[%s] [INFO] Default branch set to %s\n' "$(date)" "$default_branch"
      else
        printf '[%s] [WARNING] Could not set default branch to %s (HTTP %s)\n' "$(date)" "$default_branch" "$status"
      fi
    fi

    printf '[%s] [SUCCESS] Migrated with %s LFS object(s): %s/%s -> %s/%s\n' "$(date)" "$objects" "$pk" "$slug" "$org" "$ghr"
    rm -rf "$work"
    printf 'Success%s%s%s%s\n' "$SEP" "$objects" "$SEP" "$map_file" > "$res"
  } >> "$log_file" 2>&1
}

run_migrate() {
  git lfs version >/dev/null 2>&1 || { log_error "git-lfs is required (https://git-lfs.com)."; exit 1; }
  GH_HOST="$(derive_gh_host)"
  GH_TOKEN_VALUE="${GH_PAT:-${GH_TOKEN:-}}"
  if [[ -z "$GH_TOKEN_VALUE" ]] && command -v gh >/dev/null 2>&1; then
    GH_TOKEN_VALUE="$(gh auth token --hostname "$GH_HOST" 2>/dev/null || true)"
  fi
  [[ -n "$GH_TOKEN_VALUE" ]] || { log_error "Set GH_PAT (or GH_TOKEN, or run gh auth login)."; exit 1; }
  GH_AUTH="Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN_VALUE" | base64 | tr -d '\n')"

  read_csv_rows "$LARGE_CSV"
  MIG_ROWS=("${ROWS[@]}")
  local out_csv="large-file-migration-output-${timestamp}.csv"
  echo "${CSV_HEADER},Migration_Status,LFS_Objects,SHA_Map,Log_File" > "$out_csv"
  if (( ${#MIG_ROWS[@]} == 0 )); then
    log_warning "${LARGE_CSV} lists no repositories. Run with --detect first, or add rows to it."
    log_info "Wrote ${out_csv}"
    exit 0
  fi

  set_git_config_env
  preflight

  local i pk pn repo org ghr vis safe
  LOGS=(); MAPS=()
  for i in "${!MIG_ROWS[@]}"; do
    IFS="$SEP" read -r pk pn repo org ghr vis <<< "${MIG_ROWS[$i]}"
    safe="$(printf '%s-%s' "$pk" "$repo" | tr -c 'A-Za-z0-9._-' '_')"
    LOGS[$i]="large-file-migration-${safe}-${timestamp}.txt"
    MAPS[$i]="large-file-sha-map-${safe}-${timestamp}.csv"
  done

  log_warning "Converting files above ${CONVERT_ABOVE_MB} MB to Git LFS rewrites history: commit SHAs in GitHub will differ from Bitbucket."
  log_info "Migrating ${#MIG_ROWS[@]} large-file repositories (${MAX_CONCURRENT} in parallel) to ${GH_HOST}..."
  run_pool "$MAX_CONCURRENT" migrate_one "${!MIG_ROWS[@]}"

  local ok=0 failed=0 status objects map res
  for i in "${!MIG_ROWS[@]}"; do
    IFS="$SEP" read -r pk pn repo org ghr vis <<< "${MIG_ROWS[$i]}"
    res="${WORK_TMP}/result-${i}"
    status="Failure"; objects="0"; map=""
    [[ -s "$res" ]] && IFS="$SEP" read -r status objects map < "$res"
    if [[ "$status" == "Success" ]]; then
      ok=$(( ok + 1 )); log_success "${pk}/${repo} -> ${org}/${ghr}: migrated, ${objects} LFS object(s)"
    else
      failed=$(( failed + 1 )); log_error "${pk}/${repo} -> ${org}/${ghr}: failed (see ${LOGS[$i]})"
    fi
    csv_row "$pk" "$pn" "$repo" "$org" "$ghr" "$vis" "$status" "$objects" "$map" "${LOGS[$i]}" >> "$out_csv"
  done

  echo ""
  echo "[SUMMARY] Large-file repos: ${#MIG_ROWS[@]} / Migrated: ${ok} / Failed: ${failed}"
  log_info "Wrote large-file migration results: ${out_csv}"
  if (( failed > 0 )); then
    echo "::error::Large-file migration failed for ${failed} repository(ies)."
    exit 1
  fi
  exit 0
}

case "$MODE" in
  detect) run_detect ;;
  list) run_list ;;
  *) run_migrate ;;
esac
