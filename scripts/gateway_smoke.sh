#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
API_KEY="${API_KEY:-test-key}"
MODEL="${MODEL:-gpt-4o}"
CHAT_MODEL="${CHAT_MODEL:-$MODEL}"
RESPONSES_MODEL="${RESPONSES_MODEL:-$MODEL}"
MESSAGES_MODEL="${MESSAGES_MODEL:-${ANTHROPIC_MODEL:-claude-sonnet-4.6}}"
REQUESTS="${REQUESTS:-24}"
CONCURRENCY="${CONCURRENCY:-6}"
MAX_TIME="${MAX_TIME:-180}"

tmpdir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmpdir"
}
trap cleanup EXIT

curl_json() {
	local path="$1"
	local payload="$2"
	curl -fsS -N --max-time "$MAX_TIME" \
		-H "Authorization: Bearer ${API_KEY}" \
		-H "Content-Type: application/json" \
		-d "$payload" \
		"${BASE_URL}${path}"
}

check_contains() {
	local file="$1"
	local expected="$2"
	if ! grep -q "$expected" "$file"; then
		echo "expected ${file} to contain ${expected}" >&2
		echo "--- body ---" >&2
		cat "$file" >&2
		exit 1
	fi
}

chat_payload="$(cat <<JSON
{
	"model": "$CHAT_MODEL",
	"stream": true,
	"messages": [
		{"role": "system", "content": "You are validating a gateway smoke test. Use the provided fictional tool result and keep the answer terse."},
		{"role": "user", "content": "What is the current status of ticket T-100?"},
		{
			"role": "assistant",
			"content": "I will inspect the ticket.",
			"tool_calls": [
				{
					"id": "call_smoke_lookup_ticket",
					"type": "function",
					"function": {"name": "lookup_ticket", "arguments": "{\"ticket_id\":\"T-100\"}"}
				}
			]
		},
		{"role": "tool", "tool_call_id": "call_smoke_lookup_ticket", "content": "{\"ticket_id\":\"T-100\",\"status\":\"green\",\"owner\":\"chat-smoke\"}"},
		{"role": "user", "content": "Answer from the fictional tool result in one sentence."}
	],
	"tools": [
		{
			"type": "function",
			"function": {
				"name": "lookup_ticket",
				"description": "Look up a fictional support ticket for smoke testing.",
				"parameters": {
					"type": "object",
					"properties": {"ticket_id": {"type": "string"}},
					"required": ["ticket_id"],
					"additionalProperties": false
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "create_followup",
				"description": "Create a fictional follow-up task for smoke testing.",
				"parameters": {
					"type": "object",
					"properties": {"summary": {"type": "string"}, "priority": {"type": "string", "enum": ["low", "normal", "high"]}},
					"required": ["summary"],
					"additionalProperties": false
				}
			}
		}
	],
	"tool_choice": "none",
	"parallel_tool_calls": false,
	"stream_options": {"include_usage": true}
}
JSON
)"

responses_payload="$(cat <<JSON
{
	"model": "$RESPONSES_MODEL",
	"stream": true,
	"input": [
		{"role": "developer", "content": "You are validating a gateway smoke test. Use the provided fictional tool result and keep the answer terse."},
		{"role": "user", "content": [{"type": "input_text", "text": "What is the current status of ticket T-200?"}]},
		{"type": "function_call", "call_id": "call_smoke_lookup_ticket", "name": "lookup_ticket", "arguments": "{\"ticket_id\":\"T-200\"}"},
		{"type": "function_call_output", "call_id": "call_smoke_lookup_ticket", "output": "{\"ticket_id\":\"T-200\",\"status\":\"green\",\"owner\":\"responses-smoke\"}"},
		{"role": "user", "content": [{"type": "input_text", "text": "Answer from the fictional tool result in one sentence."}]}
	],
	"tools": [
		{
			"type": "function",
			"name": "lookup_ticket",
			"description": "Look up a fictional support ticket for smoke testing.",
			"parameters": {
				"type": "object",
				"properties": {"ticket_id": {"type": "string"}},
				"required": ["ticket_id"],
				"additionalProperties": false
			}
		},
		{
			"type": "function",
			"name": "create_followup",
			"description": "Create a fictional follow-up task for smoke testing.",
			"parameters": {
				"type": "object",
				"properties": {"summary": {"type": "string"}, "priority": {"type": "string", "enum": ["low", "normal", "high"]}},
				"required": ["summary"],
				"additionalProperties": false
			}
		}
	],
	"tool_choice": "none",
	"parallel_tool_calls": false,
	"stream_options": {"include_usage": true}
}
JSON
)"

messages_payload="$(cat <<JSON
{
	"model": "$MESSAGES_MODEL",
	"stream": true,
	"max_tokens": 1024,
	"system": [{"type": "text", "text": "You are validating a gateway smoke test. Use the provided fictional tool result and keep the answer terse."}],
	"messages": [
		{"role": "user", "content": [{"type": "text", "text": "What is the current status of ticket T-300?"}]},
		{
			"role": "assistant",
			"content": [
				{"type": "text", "text": "I will inspect the ticket."},
				{"type": "tool_use", "id": "toolu_smoke_lookup_ticket", "name": "lookup_ticket", "input": {"ticket_id": "T-300"}}
			]
		},
		{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_smoke_lookup_ticket", "content": [{"type": "text", "text": "{\"ticket_id\":\"T-300\",\"status\":\"green\",\"owner\":\"messages-smoke\"}"}]}]},
		{"role": "user", "content": [{"type": "text", "text": "Answer from the fictional tool result in one sentence."}]}
	],
	"tools": [
		{
			"name": "lookup_ticket",
			"description": "Look up a fictional support ticket for smoke testing.",
			"input_schema": {
				"type": "object",
				"properties": {"ticket_id": {"type": "string"}},
				"required": ["ticket_id"],
				"additionalProperties": false
			}
		},
		{
			"name": "create_followup",
			"description": "Create a fictional follow-up task for smoke testing.",
			"input_schema": {
				"type": "object",
				"properties": {"summary": {"type": "string"}, "priority": {"type": "string", "enum": ["low", "normal", "high"]}},
				"required": ["summary"],
				"additionalProperties": false
			}
		}
	],
	"tool_choice": {"type": "none"}
}
JSON
)"

echo "smoke: health"
curl -fsS --max-time 10 "${BASE_URL}/healthz" >/dev/null

echo "smoke: /v1/chat/completions stream with standard tool history"
chat_out="${tmpdir}/chat.sse"
curl_json "/v1/chat/completions" "$chat_payload" >"$chat_out"
check_contains "$chat_out" "data:"
check_contains "$chat_out" "\[DONE\]"

echo "smoke: /v1/responses stream with standard tool history"
responses_out="${tmpdir}/responses.sse"
curl_json "/v1/responses" "$responses_payload" >"$responses_out"
check_contains "$responses_out" "response.output_text.delta"
check_contains "$responses_out" "response.completed"

echo "smoke: /v1/messages stream with standard tool history"
messages_out="${tmpdir}/messages.sse"
curl_json "/v1/messages" "$messages_payload" >"$messages_out"
check_contains "$messages_out" "message_start"
check_contains "$messages_out" "content_block_delta"
check_contains "$messages_out" "message_stop"

echo "load: ${REQUESTS} chat streams at concurrency ${CONCURRENCY}"
seq 1 "$REQUESTS" | xargs -P "$CONCURRENCY" -I{} sh -c '
	out="'"$tmpdir"'/load_{}.sse"
	curl -fsS -N --max-time "'"$MAX_TIME"'" \
		-H "Authorization: Bearer '"$API_KEY"'" \
		-H "Content-Type: application/json" \
		-d "{\"model\":\"'"$CHAT_MODEL"'\",\"stream\":true,\"messages\":[{\"role\":\"system\",\"content\":\"Use fictional tools only when needed.\"},{\"role\":\"user\",\"content\":\"Smoke load request {} for ticket T-LOAD.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"lookup_ticket\",\"description\":\"Look up a fictional support ticket.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"ticket_id\":{\"type\":\"string\"}},\"required\":[\"ticket_id\"],\"additionalProperties\":false}}}],\"tool_choice\":\"none\"}" \
		"'"$BASE_URL"'/v1/chat/completions" >"$out"
	grep -q "\[DONE\]" "$out"
'

echo "ok"