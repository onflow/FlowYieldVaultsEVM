#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_MAX_DIFF_SIZE=150000
readonly CLAUDE_ENDPOINT="https://api.anthropic.com/v1/messages"
readonly OPENAI_ENDPOINT="https://api.openai.com/v1/chat/completions"
readonly CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-20250514}"
readonly OPENAI_MODEL="${OPENAI_MODEL:-gpt-4o}"
readonly GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.0-flash-exp}"

WORK_DIR="$(mktemp -d)"
TRANSCRIPT_FILE="${WORK_DIR}/transcript.json"
echo "[]" > "${TRANSCRIPT_FILE}"

declare -a PROVIDER_LIST=()
SANITIZED_DIFF=""

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

log_info() {
  echo "[INFO] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Missing required command: ${cmd}"
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log_error "Missing required environment variable: ${name}"
    exit 1
  fi
}

write_output() {
  local key="$1"
  local value="$2"
  local multiline="${3:-false}"

  if [[ "${multiline}" == "true" ]]; then
    local delimiter="EOF_${key}_$RANDOM"
    {
      echo "${key}<<${delimiter}"
      echo "${value}"
      echo "${delimiter}"
    } >> "${GITHUB_OUTPUT}"
  else
    echo "${key}=${value}" >> "${GITHUB_OUTPUT}"
  fi
}

parse_providers() {
  local raw="${PROVIDERS:-claude,openai}"
  IFS=',' read -r -a tokens <<< "${raw}"

  for token in "${tokens[@]}"; do
    local provider
    provider="$(echo "${token}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${provider}" ]] && continue

    case "${provider}" in
      claude|openai|gemini)
        ;;
      *)
        log_error "Unsupported provider '${provider}'. Allowed: claude, openai, gemini"
        exit 1
        ;;
    esac

    local exists="false"
    for existing in "${PROVIDER_LIST[@]:-}"; do
      if [[ "${existing}" == "${provider}" ]]; then
        exists="true"
        break
      fi
    done

    if [[ "${exists}" == "false" ]]; then
      PROVIDER_LIST+=("${provider}")
    fi
  done

  if [[ "${#PROVIDER_LIST[@]}" -lt 2 ]]; then
    log_error "Multi-round debate requires at least 2 providers. Got: ${#PROVIDER_LIST[@]}"
    exit 1
  fi
}

validate_provider_keys() {
  for provider in "${PROVIDER_LIST[@]}"; do
    case "${provider}" in
      claude)
        require_env "CLAUDE_API_KEY"
        ;;
      openai)
        require_env "OPENAI_API_KEY"
        ;;
      gemini)
        require_env "GEMINI_API_KEY"
        ;;
    esac
  done
}

sanitize_diff() {
  local diff="$1"

  diff="$(printf '%s\n' "${diff}" | sed -E 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii][-_]?[Kk][Ee][Yy])[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=***REDACTED***/g')"
  diff="$(printf '%s\n' "${diff}" | sed -E 's/gh[ps]_[A-Za-z0-9]{36}/***GITHUB-TOKEN-REDACTED***/g')"
  diff="$(printf '%s\n' "${diff}" | sed -E 's/sk-[A-Za-z0-9_-]{20,}/***API-KEY-REDACTED***/g')"
  diff="$(printf '%s\n' "${diff}" | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/***EMAIL-REDACTED***/g')"

  echo "${diff}"
}

strip_markdown_wrapper() {
  local text="$1"
  if printf '%s\n' "${text}" | grep -q '^```'; then
    text="$(printf '%s\n' "${text}" | sed '/^```[A-Za-z0-9_-]*$/d')"
  fi
  echo "${text}"
}

normalize_response() {
  local provider="$1"
  local raw="$2"
  local normalized

  if ! normalized="$(printf '%s' "${raw}" | jq -cer '
    def clean($max):
      tostring
      | gsub("[\r\n]+"; " ")
      | .[0:$max];
    {
      risk: (
        (.risk // "high")
        | tostring
        | ascii_downcase
        | if . == "low" then "low" else "high" end
      ),
      confidence: (
        (.confidence // 50)
        | tonumber? // 50
        | floor
        | if . < 0 then 0 elif . > 100 then 100 else . end
      ),
      reasoning: ((.reasoning // "No reasoning provided") | clean(240)),
      concerns: (
        (.concerns // [])
        | if type == "array" then . else [] end
        | map(clean(180))
        | .[0:5]
      ),
      counterpoints: (
        (.counterpoints // [])
        | if type == "array" then . else [] end
        | map(clean(180))
        | .[0:5]
      ),
      changed_position: (
        (.changed_position // false)
        | if type == "boolean" then . else false end
      )
    }')"; then
    log_error "Provider ${provider} returned invalid JSON"
    log_error "Raw output preview: $(printf '%s' "${raw}" | head -c 500)"
    return 1
  fi

  printf '%s' "${normalized}"
}

call_claude() {
  local prompt="$1"
  local payload_file="${WORK_DIR}/claude-payload.json"
  local response_file="${WORK_DIR}/claude-response.json"

  jq -n \
    --arg model "${CLAUDE_MODEL}" \
    --arg prompt "${prompt}" \
    '{
      model: $model,
      max_tokens: 1200,
      system: "You are a JSON-only assistant. Return valid JSON only.",
      messages: [{role: "user", content: $prompt}]
    }' > "${payload_file}"

  curl -sS --fail-with-body \
    --max-time 90 \
    -X POST "${CLAUDE_ENDPOINT}" \
    -H "content-type: application/json" \
    -H "x-api-key: ${CLAUDE_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    --data "@${payload_file}" > "${response_file}"

  jq -re '.content[0].text' "${response_file}"
}

call_openai() {
  local prompt="$1"
  local payload_file="${WORK_DIR}/openai-payload.json"
  local response_file="${WORK_DIR}/openai-response.json"

  jq -n \
    --arg model "${OPENAI_MODEL}" \
    --arg prompt "${prompt}" \
    '{
      model: $model,
      messages: [
        {role: "system", content: "You are a JSON-only assistant. Return valid JSON only."},
        {role: "user", content: $prompt}
      ],
      temperature: 0,
      response_format: {type: "json_object"}
    }' > "${payload_file}"

  curl -sS --fail-with-body \
    --max-time 90 \
    -X POST "${OPENAI_ENDPOINT}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    --data "@${payload_file}" > "${response_file}"

  jq -re '.choices[0].message.content' "${response_file}"
}

call_gemini() {
  local prompt="$1"
  local payload_file="${WORK_DIR}/gemini-payload.json"
  local response_file="${WORK_DIR}/gemini-response.json"
  local endpoint="https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent"

  jq -n \
    --arg prompt "${prompt}" \
    '{
      contents: [{parts: [{text: $prompt}]}],
      generationConfig: {response_mime_type: "application/json"}
    }' > "${payload_file}"

  curl -sS --fail-with-body \
    --max-time 90 \
    -X POST "${endpoint}" \
    -H "Content-Type: application/json" \
    -H "x-goog-api-key: ${GEMINI_API_KEY}" \
    --data "@${payload_file}" > "${response_file}"

  jq -re '.candidates[0].content.parts[0].text' "${response_file}"
}

call_provider() {
  local provider="$1"
  local prompt="$2"
  local raw

  case "${provider}" in
    claude)
      raw="$(call_claude "${prompt}")"
      ;;
    openai)
      raw="$(call_openai "${prompt}")"
      ;;
    gemini)
      raw="$(call_gemini "${prompt}")"
      ;;
    *)
      log_error "Unknown provider: ${provider}"
      return 1
      ;;
  esac

  raw="$(strip_markdown_wrapper "${raw}")"
  normalize_response "${provider}" "${raw}"
}

build_peer_context() {
  local previous_round="$1"
  local provider="$2"
  local context=""

  if [[ "${previous_round}" -lt 1 ]]; then
    echo "No prior round context."
    return 0
  fi

  for peer in "${PROVIDER_LIST[@]}"; do
    local result_file="${WORK_DIR}/round-${previous_round}-${peer}.json"
    [[ -f "${result_file}" ]] || continue

    local risk
    local confidence
    local reasoning
    local concerns

    risk="$(jq -r '.risk' "${result_file}")"
    confidence="$(jq -r '.confidence' "${result_file}")"
    reasoning="$(jq -r '.reasoning' "${result_file}")"
    concerns="$(jq -r '.concerns | join("; ")' "${result_file}")"
    [[ -z "${concerns}" ]] && concerns="none"

    if [[ "${peer}" == "${provider}" ]]; then
      context+=$'\n'"- Your prior view (${peer}): risk=${risk}, confidence=${confidence}, reasoning=${reasoning}, concerns=${concerns}"
    else
      context+=$'\n'"- Peer view (${peer}): risk=${risk}, confidence=${confidence}, reasoning=${reasoning}, concerns=${concerns}"
    fi
  done

  echo "${context}"
}

build_prompt() {
  local provider="$1"
  local round="$2"
  local peer_context="$3"
  local diff="$4"
  local tolerance="${RISK_TOLERANCE:-moderate}"

  local phase_instruction
  if [[ "${round}" -eq 1 ]]; then
    phase_instruction="Round 1: perform an independent review."
  else
    phase_instruction="Round ${round}: review peer positions, challenge weak logic, and update your position only if the evidence supports it."
  fi

  cat <<EOF
You are ${provider}, participating in a multi-LLM PR risk debate.
${phase_instruction}

Task:
1. Assess the PR diff risk using tolerance=${tolerance}.
2. In rounds >=2, critically evaluate peer arguments and decide whether to keep or change your stance.
3. Prefer safety if uncertain.

Rules:
- Risk must be exactly "low" or "high".
- Confidence must be an integer 0..100.
- Reasoning must be one concise sentence.
- concerns and counterpoints should contain concrete points from the diff or peer arguments.
- Output JSON only.

Required JSON schema:
{"risk":"low|high","confidence":0,"reasoning":"...","concerns":["..."],"counterpoints":["..."],"changed_position":false}

Prior round context:
${peer_context}

Diff:
${diff}
EOF
}

run_provider_round() {
  local round="$1"
  local provider="$2"
  local peer_context
  local prompt
  local normalized
  local result_file

  peer_context="$(build_peer_context "$((round - 1))" "${provider}")"
  prompt="$(build_prompt "${provider}" "${round}" "${peer_context}" "${SANITIZED_DIFF}")"
  normalized="$(call_provider "${provider}" "${prompt}")"

  result_file="${WORK_DIR}/round-${round}-${provider}.json"
  printf '%s' "${normalized}" > "${result_file}"
}

append_transcript_entry() {
  local round="$1"
  local provider="$2"
  local result_json="$3"
  local tmp_file="${WORK_DIR}/transcript.tmp.json"

  jq \
    --argjson round "${round}" \
    --arg provider "${provider}" \
    --argjson payload "${result_json}" \
    '. + [($payload + {round: $round, provider: $provider})]' \
    "${TRANSCRIPT_FILE}" > "${tmp_file}"
  mv "${tmp_file}" "${TRANSCRIPT_FILE}"
}

all_providers_agree() {
  local round="$1"
  local first_risk=""

  for provider in "${PROVIDER_LIST[@]}"; do
    local result_file="${WORK_DIR}/round-${round}-${provider}.json"
    local risk
    risk="$(jq -r '.risk' "${result_file}")"
    if [[ -z "${first_risk}" ]]; then
      first_risk="${risk}"
      continue
    fi
    if [[ "${risk}" != "${first_risk}" ]]; then
      return 1
    fi
  done

  echo "${first_risk}"
  return 0
}

build_round_markdown() {
  local round="$1"
  local md="### Round ${round}"$'\n'

  for provider in "${PROVIDER_LIST[@]}"; do
    local file="${WORK_DIR}/round-${round}-${provider}.json"
    local risk
    local confidence
    local reasoning
    local concerns
    local counterpoints
    local changed

    risk="$(jq -r '.risk' "${file}")"
    confidence="$(jq -r '.confidence' "${file}")"
    reasoning="$(jq -r '.reasoning' "${file}")"
    concerns="$(jq -r '.concerns | if length == 0 then "none" else join("; ") end' "${file}")"
    counterpoints="$(jq -r '.counterpoints | if length == 0 then "none" else join("; ") end' "${file}")"
    changed="$(jq -r '.changed_position' "${file}")"

    md+="- **${provider}**: \`${risk}\` (confidence ${confidence}, changed=${changed})"$'\n'
    md+="  reasoning: ${reasoning}"$'\n'
    md+="  concerns: ${concerns}"$'\n'
    md+="  counterpoints: ${counterpoints}"$'\n'
  done

  echo "${md}"
}

main() {
  require_cmd "jq"
  require_cmd "curl"
  require_env "DIFF_FILE"
  require_env "GITHUB_OUTPUT"

  if [[ ! -f "${DIFF_FILE}" ]]; then
    log_error "Diff file not found: ${DIFF_FILE}"
    exit 1
  fi

  parse_providers
  validate_provider_keys

  local diff_size
  local max_diff_size="${MAX_DEBATE_DIFF_SIZE:-${DEFAULT_MAX_DIFF_SIZE}}"

  if ! [[ "${max_diff_size}" =~ ^[0-9]+$ ]]; then
    log_error "MAX_DEBATE_DIFF_SIZE must be an integer"
    exit 1
  fi

  diff_size="$(wc -c < "${DIFF_FILE}" | tr -d ' ')"
  if [[ "${diff_size}" -gt "${max_diff_size}" ]]; then
    log_error "Diff too large (${diff_size} bytes > ${max_diff_size})"
    exit 1
  fi

  local max_rounds="${MAX_DEBATE_ROUNDS:-4}"
  local min_rounds="${MIN_DEBATE_ROUNDS:-2}"

  if ! [[ "${max_rounds}" =~ ^[0-9]+$ ]] || ! [[ "${min_rounds}" =~ ^[0-9]+$ ]]; then
    log_error "MAX_DEBATE_ROUNDS and MIN_DEBATE_ROUNDS must be integers"
    exit 1
  fi

  if (( min_rounds < 1 )); then
    min_rounds=1
  fi
  if (( max_rounds < min_rounds )); then
    log_error "MAX_DEBATE_ROUNDS (${max_rounds}) cannot be lower than MIN_DEBATE_ROUNDS (${min_rounds})"
    exit 1
  fi

  local raw_diff
  raw_diff="$(cat "${DIFF_FILE}")"
  SANITIZED_DIFF="$(sanitize_diff "${raw_diff}")"

  local converged="false"
  local final_risk="high"
  local rounds_completed=0
  local rounds_markdown=""
  local consensus_risk=""

  local providers_csv
  providers_csv="$(IFS=,; echo "${PROVIDER_LIST[*]}")"
  log_info "Starting debate with providers: ${providers_csv}; min_rounds=${min_rounds}, max_rounds=${max_rounds}"

  local round
  for round in $(seq 1 "${max_rounds}"); do
    log_info "Starting round ${round}"

    local -a pids=()
    for provider in "${PROVIDER_LIST[@]}"; do
      run_provider_round "${round}" "${provider}" &
      pids+=("$!")
    done

    local provider_failure="false"
    for pid in "${pids[@]}"; do
      if ! wait "${pid}"; then
        provider_failure="true"
      fi
    done

    if [[ "${provider_failure}" == "true" ]]; then
      log_error "At least one provider call failed in round ${round}"
      exit 1
    fi

    for provider in "${PROVIDER_LIST[@]}"; do
      local result_file="${WORK_DIR}/round-${round}-${provider}.json"
      local normalized
      normalized="$(cat "${result_file}")"
      append_transcript_entry "${round}" "${provider}" "${normalized}"
    done

    rounds_markdown+=$'\n'"$(build_round_markdown "${round}")"$'\n'
    rounds_completed="${round}"

    if consensus_risk="$(all_providers_agree "${round}")"; then
      log_info "Round ${round}: all providers agree on risk=${consensus_risk}"
      if (( round >= min_rounds )); then
        converged="true"
        final_risk="${consensus_risk}"
        break
      fi
    else
      log_info "Round ${round}: no consensus yet"
    fi
  done

  if [[ "${converged}" != "true" ]]; then
    final_risk="high"
    log_info "No convergence reached after ${rounds_completed} rounds; defaulting final_risk=high"
  fi

  local report_header="<!-- multi-llm-debate-review -->
## Multi-LLM Debate Review
- providers: ${providers_csv}
- rounds completed: ${rounds_completed}/${max_rounds}
- minimum rounds before convergence: ${min_rounds}
- converged: ${converged}
- final risk: ${final_risk}
- tolerance: ${RISK_TOLERANCE:-moderate}"

  local report_footer=""
  if [[ "${converged}" == "true" ]]; then
    report_footer=$'\n'"Consensus reached after ${rounds_completed} rounds."
  else
    report_footer=$'\n'"No convergence reached. Marking as high risk and requiring manual review."
  fi

  local report_markdown="${report_header}

${rounds_markdown}
${report_footer}"

  local providers_json
  local transcript_json
  local report_json
  providers_json="$(printf '%s\n' "${PROVIDER_LIST[@]}" | jq -R . | jq -s -c .)"
  transcript_json="$(cat "${TRANSCRIPT_FILE}")"
  report_json="$(jq -cn \
    --arg converged "${converged}" \
    --arg final_risk "${final_risk}" \
    --arg risk_tolerance "${RISK_TOLERANCE:-moderate}" \
    --argjson rounds_completed "${rounds_completed}" \
    --argjson max_rounds "${max_rounds}" \
    --argjson min_rounds "${min_rounds}" \
    --argjson providers "${providers_json}" \
    --argjson transcript "${transcript_json}" \
    '{
      converged: ($converged == "true"),
      final_risk: $final_risk,
      risk_tolerance: $risk_tolerance,
      rounds_completed: $rounds_completed,
      max_rounds: $max_rounds,
      min_rounds: $min_rounds,
      providers: $providers,
      transcript: $transcript
    }')"

  write_output "converged" "${converged}" "false"
  write_output "rounds_completed" "${rounds_completed}" "false"
  write_output "final_risk" "${final_risk}" "false"
  write_output "providers" "${providers_csv}" "false"
  write_output "report_markdown" "${report_markdown}" "true"
  write_output "report_json" "${report_json}" "true"
}

main "$@"
