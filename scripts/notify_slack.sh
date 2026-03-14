#!/bin/sh

set -eu

fail() {
  printf '%s\n' "${1:-E_UNKNOWN}" >&2
  exit 1
}

debug() {
  printf '%s\n' "$1"
}

gitlab_get() {
  path="$1"
  url="${GITLAB_API_BASE_URL%/}${path}"

  curl --silent --fail \
    --request GET \
    --header "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}" \
    "$url"
}

slack_get() {
  path="$1"
  query="${2:-}"
  url="https://slack.com/api/${path}"

  if [ -n "$query" ]; then
    url="${url}?${query}"
  fi

  curl --silent --fail \
    --request GET \
    --header "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    "$url"
}

slack_post() {
  path="$1"
  body="$2"

  curl --silent --fail \
    --request POST \
    --header "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    --header "Content-Type: application/json; charset=utf-8" \
    --data "$body" \
    "https://slack.com/api/${path}"
}

[ -n "${SLACK_BOT_TOKEN:-}" ] || fail "E_NO_SLACK_BOT_TOKEN"
[ -n "${GITLAB_API_TOKEN:-}" ] || fail "E_NO_GITLAB_API_TOKEN"
debug "START"

payload_path="${TRIGGER_PAYLOAD:-}"
payload_json="${TRIGGER_PAYLOAD_JSON:-}"

if [ -n "$payload_path" ]; then
  [ -f "$payload_path" ] || fail "E_TRIGGER_PAYLOAD_FILE_MISSING"
  payload="$(cat "$payload_path")"
elif [ -n "$payload_json" ]; then
  payload="$payload_json"
else
  fail "E_TRIGGER_PAYLOAD_MISSING"
fi
debug "PAYLOAD_LOADED"

gitlab_web_base_url="$(
  printf '%s' "$payload" | jq -r '
    [.project.web_url, .repository.homepage, .object_attributes.url]
    | map(select(. != null and . != ""))
    | .[0] // ""
    | if test("^https?://[^/]+") then capture("^(?<base>https?://[^/]+)").base else "" end
  '
)"
[ -n "$gitlab_web_base_url" ] || fail "E_GITLAB_BASE_URL_UNRESOLVED"
GITLAB_API_BASE_URL="${gitlab_web_base_url}/api/v4"
debug "GITLAB_API_BASE_URL_RESOLVED"

action="$(printf '%s' "$payload" | jq -r '.object_attributes.action // ""')"
if [ -n "$action" ] && [ "$action" != "create" ]; then
  fail "E_UNSUPPORTED_COMMENT_ACTION"
fi

noteable_type_raw="$(printf '%s' "$payload" | jq -r '.object_attributes.noteable_type // ""')"
noteable_type_lower="$(printf '%s' "$noteable_type_raw" | tr '[:upper:]' '[:lower:]')"
case "$noteable_type_lower" in
  merge_request)
    noteable_type="Merge Request"
    reference_prefix="!"
    ;;
  issue)
    noteable_type="Issue"
    reference_prefix="#"
    ;;
  *) fail "E_UNSUPPORTED_NOTEABLE_TYPE" ;;
esac
debug "NOTEABLE_TYPE_RESOLVED"

actor_name="$(printf '%s' "$payload" | jq -r '.user.username // .user.name // "Unknown"')"

project_id="$(printf '%s' "$payload" | jq -r '.project.id // ""')"
project_name="$(printf '%s' "$payload" | jq -r '.project.path_with_namespace // .project.name // "Unknown Project"')"
reference="$(printf '%s' "$payload" | jq -r '.merge_request.iid // .issue.iid // .object_attributes.noteable_iid // .object_attributes.id // "?" | tostring')"
note="$(printf '%s' "$payload" | jq -r '.object_attributes.note // ""')"
url="$(printf '%s' "$payload" | jq -r '.object_attributes.url // ""')"
prefix="${SLACK_MESSAGE_PREFIX:-}"

quoted_note="$(printf '%s' "$note" | sed 's/^/>/' )"
header_text="# ${actor_name} / [${project_name}${reference_prefix}${reference}](${url})"
if [ -n "$prefix" ]; then
  header_text="$(printf '%s\n%s' "$prefix" "$header_text")"
fi
fallback_text="$(printf '%s / %s%s%s %s' "$actor_name" "$project_name" "$reference_prefix" "$reference" "$url")"

case "$noteable_type_lower" in
  merge_request) participants_path="/projects/${project_id}/merge_requests/${reference}/participants" ;;
  issue) participants_path="/projects/${project_id}/issues/${reference}/participants" ;;
  *) fail "E_PARTICIPANTS_PATH_UNRESOLVED" ;;
esac
debug "PARTICIPANTS_PATH_RESOLVED"

participants_response="$(gitlab_get "$participants_path")"
debug "PARTICIPANTS_FETCHED"

participant_emails="$(
  printf '%s' "$participants_response" | jq -r \
    '
    map(.id)
    | unique
    | .[]
    '
)"

participants_count=0
public_email_found_count=0
slack_lookup_success_count=0
message_sent_count=0
participant_candidates_count="$(printf '%s\n' "$participant_emails" | jq -Rsc 'split("\n") | map(select(. != "")) | length')"
debug "PARTICIPANT_CANDIDATES_COUNT=${participant_candidates_count}"

[ -n "$participant_emails" ] || {
  debug "PARTICIPANTS_COUNT=0 PUBLIC_EMAIL_FOUND=0 SLACK_LOOKUP_SUCCESS=0 MESSAGE_SENT=0"
  exit 0
}

for participant_id in $participant_emails; do
  participants_count=$((participants_count + 1))
  debug "PARTICIPANT_LOOP_INDEX=${participants_count}"
  user_response="$(gitlab_get "/users/${participant_id}" || true)"
  [ -n "$user_response" ] || {
    debug "USER_FETCH_SKIPPED"
    continue
  }
  target_email="$(printf '%s' "$user_response" | jq -r '.public_email // ""')"
  [ -n "$target_email" ] || {
    debug "PUBLIC_EMAIL_MISSING"
    continue
  }
  public_email_found_count=$((public_email_found_count + 1))
  email_query="email=$(jq -rn --arg email "$target_email" '$email|@uri')"

  lookup_response="$(slack_get "users.lookupByEmail" "$email_query" || true)"
  [ -n "$lookup_response" ] || {
    debug "SLACK_LOOKUP_EMPTY"
    continue
  }
  lookup_ok="$(printf '%s' "$lookup_response" | jq -r '.ok // false')"
  [ "$lookup_ok" = "true" ] || {
    debug "SLACK_LOOKUP_NOT_OK"
    continue
  }
  slack_lookup_success_count=$((slack_lookup_success_count + 1))

  user_id="$(printf '%s' "$lookup_response" | jq -r '.user.id // ""')"
  [ -n "$user_id" ] || {
    debug "SLACK_USER_ID_MISSING"
    continue
  }

  post_body="$(jq -n \
    --arg channel "$user_id" \
    --arg text "$fallback_text" \
    --arg header_text "$header_text" \
    --arg comment_text "$quoted_note" \
    --arg button_url "$url" \
    '{
      channel: $channel,
      text: $text,
      blocks: [
        {
          type: "markdown",
          text: $header_text
        },
        {
          type: "markdown",
          text: $comment_text
        },
        {
          type: "actions",
          elements: [
            {
              type: "button",
              text: {
                type: "plain_text",
                text: "Open GitLab",
                emoji: true
              },
              value: "open_gitlab",
              action_id: "open-gitlab",
              url: $button_url
            }
          ]
        }
      ]
    }')"

  post_response="$(slack_post "chat.postMessage" "$post_body" || true)"
  [ -n "$post_response" ] || {
    debug "SLACK_POST_EMPTY"
    continue
  }
  post_ok="$(printf '%s' "$post_response" | jq -r '.ok // false')"
  [ "$post_ok" = "true" ] || {
    debug "SLACK_POST_NOT_OK"
    continue
  }
  message_sent_count=$((message_sent_count + 1))
  debug "MESSAGE_SENT_OK"
done

printf 'PARTICIPANTS_COUNT=%s\n' "$participants_count"
printf 'PUBLIC_EMAIL_FOUND=%s\n' "$public_email_found_count"
printf 'SLACK_LOOKUP_SUCCESS=%s\n' "$slack_lookup_success_count"
printf 'MESSAGE_SENT=%s\n' "$message_sent_count"
