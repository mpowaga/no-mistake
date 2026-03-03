#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./mistake.sh [-m MODEL|--model MODEL] [-s N|--max-steps N] [-A|--accept-mistakes] ["your task"]

Input:
  Task can be provided as an argument or via stdin.
  Example: ./mistake.sh < README.md

Options:
  -m, --model MODEL  OpenAI model to use (default: gpt-4.1-mini).
  -s, --max-steps N  Maximum number of command steps (default: 50).
  -A, --accept-mistakes  Run commands without asking for approval.

Environment variables:
  OPENAI_API_KEY   Required. Your OpenAI API key.
EOF
}

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: missing required command '$1'" >&2
    exit 1
  fi
}

prompt_command_approval() {
  local answer
  while true; do
    if [ -r /dev/tty ]; then
      printf "Approve command? [Y/n] " >/dev/tty
      if ! IFS= read -r answer < /dev/tty; then
        printf '\n' >/dev/tty
        return 1
      fi
    else
      printf "Approve command? [Y/n] "
      if ! IFS= read -r answer; then
        echo
        return 1
      fi
    fi
    case "$answer" in
      ""|y|Y|yes|YES|Yes)
        return 0
        ;;
      n|N|no|NO|No)
        return 1
        ;;
      *)
        if [ -r /dev/tty ]; then
          echo "Please answer Y or n." >/dev/tty
        else
          echo "Please answer Y or n."
        fi
        ;;
    esac
  done
}

THINKING_PID=""

start_thinking() {
  if [ ! -t 1 ]; then
    return
  fi
  if [ -n "${THINKING_PID:-}" ]; then
    return
  fi

  (
    trap 'exit 0' TERM INT
    local frames='|/-\'
    local i=0
    while true; do
      printf '\rThinking... %s' "${frames:$i:1}"
      i=$(( (i + 1) % 4 ))
      sleep 0.1
    done
  ) &
  THINKING_PID=$!
}

stop_thinking() {
  if [ -z "${THINKING_PID:-}" ]; then
    return
  fi
  kill "$THINKING_PID" >/dev/null 2>&1 || true
  wait "$THINKING_PID" 2>/dev/null || true
  THINKING_PID=""
  if [ -t 1 ]; then
    printf '\r%*s\r' 24 ''
  fi
}

trap 'stop_thinking' EXIT INT TERM

require_bin curl
require_bin jq

MODEL="gpt-4.1-mini"
MAX_STEPS=50
ACCEPT_MISTAKES=0

args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -m|--model)
      if [ "$#" -lt 2 ]; then
        echo "Error: $1 requires a value." >&2
        usage
        exit 1
      fi
      MODEL="$2"
      shift 2
      ;;
    -s|--max-steps)
      if [ "$#" -lt 2 ]; then
        echo "Error: $1 requires a value." >&2
        usage
        exit 1
      fi
      if ! printf '%s' "$2" | jq -e 'type == "number" and . == floor and . > 0' >/dev/null 2>&1; then
        echo "Error: $1 value must be a positive integer." >&2
        exit 1
      fi
      MAX_STEPS="$2"
      shift 2
      ;;
    -A|--accept-mistakes)
      ACCEPT_MISTAKES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        args+=("$1")
        shift
      done
      ;;
    -*)
      echo "Error: unknown option '$1'." >&2
      usage
      exit 1
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

if [ "${#args[@]}" -gt 0 ]; then
  TASK="${args[*]}"
elif [ ! -t 0 ]; then
  TASK="$(cat)"
  if [ -z "$TASK" ]; then
    echo "Error: task input from stdin is empty." >&2
    exit 1
  fi
else
  usage
  exit 1
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "Error: OPENAI_API_KEY is not set." >&2
  exit 1
fi

SYSTEM_PROMPT=$(
  cat <<'EOF'
You are a terminal task agent.
Use the available tool when you need to run shell commands.
For each tool call, provide a short explanation of why the command is needed.
When the task is complete, respond with a concise final summary and do not call tools.
Before starting, scan the current directory to understand the project and use appropriate tools for that project.

MAKE NO MISTAKES
EOF
)

conversation="$(jq -nc \
  --arg sys "$SYSTEM_PROMPT" \
  --arg task "$TASK" \
  '[
    {"role":"system","content":$sys},
    {"role":"user","content":"User task: \($task)"}
  ]')"

command_step=1
previous_response_id=""

while [ "$command_step" -le "$MAX_STEPS" ]; do
  tools='[
    {
      "type": "function",
      "name": "run_bash",
      "description": "Execute a bash command in the terminal. Include a short explanation shown to the user.",
      "parameters": {
        "type": "object",
        "properties": {
          "explanation": {
            "type": "string",
            "description": "Why this command should be run now."
          },
          "command": {
            "type": "string",
            "description": "The bash command to execute."
          }
        },
        "required": ["explanation", "command"],
        "additionalProperties": false
      }
    }
  ]'

  payload="$(jq -nc \
    --arg model "$MODEL" \
    --argjson input "$conversation" \
    --arg prev "$previous_response_id" \
    --argjson tools "$tools" \
    '(
      {
        model: $model,
        input: $input,
        tools: $tools,
        tool_choice: "auto"
      }
      + (if $prev != "" then {previous_response_id: $prev} else {} end)
    )')"

  start_thinking
  set +e
  response_with_code="$(
    curl -sS \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      -w $'\n%{http_code}' \
      https://api.openai.com/v1/responses
  )"
  curl_exit_code=$?
  set -e
  stop_thinking

  if [ "$curl_exit_code" -ne 0 ]; then
    echo "OpenAI API request failed (curl exit code $curl_exit_code)." >&2
    exit 1
  fi

  http_code="$(printf '%s' "$response_with_code" | tail -n1)"
  response_body="$(printf '%s' "$response_with_code" | sed '$d')"

  if [ "$http_code" != "200" ]; then
    echo "OpenAI API error (HTTP $http_code):" >&2
    printf '%s\n' "$response_body" >&2
    exit 1
  fi

  response_id="$(printf '%s' "$response_body" | jq -r '.id // empty')"
  if [ -z "$response_id" ]; then
    echo "Error: response did not include an id." >&2
    printf '%s\n' "$response_body" >&2
    exit 1
  fi

  assistant_content="$(
    printf '%s' "$response_body" | jq -r '
      (
        [
          .output[]?
          | select(.type == "message")
          | .content[]?
          | select(.type == "output_text")
          | .text
        ] | join("\n")
      ) as $joined
      | if ($joined | length) > 0 then
          $joined
        else
          (.output_text // "")
        end
    '
  )"

  tool_calls="$(printf '%s' "$response_body" | jq -c '[.output[]? | select(.type == "function_call" and .name == "run_bash")]')"
  tool_call_count="$(printf '%s' "$tool_calls" | jq 'length')"

  if [ "$tool_call_count" -eq 0 ]; then
    if [ -n "$assistant_content" ]; then
      echo "$assistant_content"
      exit 0
    fi
    echo "Error: model returned neither tool call nor final text." >&2
    printf '%s\n' "$response_body" >&2
    exit 1
  fi

  function_outputs='[]'
  call_index=0
  while [ "$call_index" -lt "$tool_call_count" ]; do
    call_json="$(printf '%s' "$tool_calls" | jq -c ".[$call_index]")"
    call_id="$(printf '%s' "$call_json" | jq -r '.call_id // empty')"
    args_raw="$(printf '%s' "$call_json" | jq -r '.arguments // "{}"')"

    if [ -z "$call_id" ]; then
      echo "Error: tool call missing call_id." >&2
      printf '%s\n' "$call_json" >&2
      exit 1
    fi

    if ! printf '%s' "$args_raw" | jq -e . >/dev/null 2>&1; then
      tool_result="$(jq -nc \
        --arg error "Invalid tool arguments JSON: $args_raw" \
        '{error: $error}')"
      function_outputs="$(printf '%s' "$function_outputs" | jq -c \
        --arg call_id "$call_id" \
        --arg out "$tool_result" \
        '. + [{"type":"function_call_output","call_id":$call_id,"output":$out}]')"
      call_index=$((call_index + 1))
      continue
    fi

    explanation="$(printf '%s' "$args_raw" | jq -r '.explanation // ""')"
    command="$(printf '%s' "$args_raw" | jq -r '.command // ""')"

    if [ -z "$command" ]; then
      tool_result="$(jq -nc \
        --arg error "Missing command in tool arguments." \
        '{error: $error}')"
      function_outputs="$(printf '%s' "$function_outputs" | jq -c \
        --arg call_id "$call_id" \
        --arg out "$tool_result" \
        '. + [{"type":"function_call_output","call_id":$call_id,"output":$out}]')"
      call_index=$((call_index + 1))
      continue
    fi

    if [ -n "$explanation" ]; then
      reason="$explanation"
    else
      reason="Running command requested by the model."
    fi

    printf '[%s    %s]\n' "$command_step" "$reason"
    if [ -t 1 ]; then
      printf ' =>   \033[1m%s\033[0m\n\n' "$command"
    else
      printf ' =>   %s\n\n' "$command"
    fi

    if [ "$ACCEPT_MISTAKES" -eq 1 ] || prompt_command_approval; then
      output_file="$(mktemp "${TMPDIR:-/tmp}/agent-output.XXXXXX")"
      set +e
      if [ -t 1 ]; then
        bash -lc "$command" 2>&1 | tee "$output_file" | sed $'s/^/\033[90m/;s/$/\033[0m/'
        command_exit_code=${PIPESTATUS[0]}
      else
        bash -lc "$command" 2>&1 | tee "$output_file"
        command_exit_code=${PIPESTATUS[0]}
      fi
      set -e
      command_output="$(cat "$output_file")"
      rm -f "$output_file"
    else
      echo "Command rejected by user. Stopping."
      exit 130
    fi

    if [ "$command_exit_code" -ne 0 ]; then
      if [ -t 1 ]; then
        printf '\033[31m(exit code: %s)\033[0m\n' "$command_exit_code"
      else
        echo "(exit code: $command_exit_code)"
      fi
    fi
    echo

    tool_result="$(jq -nc \
      --arg exp "$explanation" \
      --arg cmd "$command" \
      --arg out "$command_output" \
      --argjson code "$command_exit_code" \
      '{
        explanation: $exp,
        command: $cmd,
        exit_code: $code,
        output: $out
      }')"

    function_outputs="$(printf '%s' "$function_outputs" | jq -c \
      --arg call_id "$call_id" \
      --arg out "$tool_result" \
      '. + [{"type":"function_call_output","call_id":$call_id,"output":$out}]')"

    command_step=$((command_step + 1))
    if [ "$command_step" -gt "$MAX_STEPS" ]; then
      break
    fi

    call_index=$((call_index + 1))
  done

  previous_response_id="$response_id"
  conversation="$function_outputs"
done

echo "Stopped after $MAX_STEPS steps without completion." >&2
exit 2
