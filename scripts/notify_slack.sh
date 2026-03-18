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
  printf '%s' "$payload" | jq -er '
    [.project.web_url, .repository.homepage, .object_attributes.url]
    | map(select(. != null and . != ""))
    | .[0]
    | capture("^(?<base>https?://[^/]+)").base
  '
)" || fail "E_GITLAB_BASE_URL_UNRESOLVED"
GITLAB_API_BASE_URL="${gitlab_web_base_url}/api/v4"
debug "GITLAB_API_BASE_URL_RESOLVED"

action="$(printf '%s' "$payload" | jq -er '.object_attributes.action')" || fail "E_ACTION_MISSING"
case "$action" in
  create|update) ;;
  *)
  fail "E_UNSUPPORTED_COMMENT_ACTION"
  ;;
esac

noteable_type="$(printf '%s' "$payload" | jq -er '.object_attributes.noteable_type')" || fail "E_NOTEABLE_TYPE_MISSING"
case "$noteable_type" in
  MergeRequest)
    reference_prefix="!"
    ;;
  Issue)
    reference_prefix="#"
    ;;
  *) fail "E_UNSUPPORTED_NOTEABLE_TYPE" ;;
esac
debug "NOTEABLE_TYPE_RESOLVED"

actor_name="$(printf '%s' "$payload" | jq -er '.user.name')" || fail "E_USER_NAME_MISSING"

project_id="$(printf '%s' "$payload" | jq -er '.project.id | tostring')" || fail "E_PROJECT_ID_MISSING"
project_name="$(printf '%s' "$payload" | jq -er '.project.path_with_namespace')" || fail "E_PROJECT_PATH_WITH_NAMESPACE_MISSING"
reference="$(printf '%s' "$payload" | jq -er '(.merge_request.iid // .issue.iid // .object_attributes.noteable_iid // .object_attributes.id) | tostring')" || fail "E_REFERENCE_MISSING"
note="$(printf '%s' "$payload" | jq -er '.object_attributes.note')" || fail "E_NOTE_MISSING"
url="$(printf '%s' "$payload" | jq -er '.object_attributes.url')" || fail "E_URL_MISSING"
prefix="${SLACK_MESSAGE_PREFIX:-}"
note_anchor="$(printf '%s' "$url" | sed -n 's/.*#\(note_[^#?&/]*\).*/\1/p')"
[ -n "$note_anchor" ] || fail "E_NOTE_ANCHOR_MISSING"

actor_username="$(printf '%s' "$payload" | jq -er '.user.username')" || fail "E_USERNAME_MISSING"
if printf '%s' "$actor_username" | grep -Fq '_bot_'; then
  debug "BOT_USER_SKIPPED"
  exit 0
fi
actor_url="${gitlab_web_base_url}/${actor_username}"
header_text="**[${actor_name}](${actor_url}) @ [${project_name}${reference_prefix}${reference}](${url})**"
if [ -n "$prefix" ]; then
  header_text="$(printf '%s\n%s' "$prefix" "$header_text")"
fi
fallback_text="$(printf '%s / %s%s%s %s' "$actor_name" "$project_name" "$reference_prefix" "$reference" "$url")"

case "$noteable_type" in
  MergeRequest) participants_path="/projects/${project_id}/merge_requests/${reference}/participants" ;;
  Issue) participants_path="/projects/${project_id}/issues/${reference}/participants" ;;
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
message_updated_count=0
participant_candidates_count="$(printf '%s\n' "$participant_emails" | jq -Rsc 'split("\n") | map(select(. != "")) | length')"
debug "PARTICIPANT_CANDIDATES_COUNT=${participant_candidates_count}"

[ -n "$participant_emails" ] || {
  debug "PARTICIPANTS_COUNT=0 PUBLIC_EMAIL_FOUND=0 SLACK_LOOKUP_SUCCESS=0 MESSAGE_SENT=0 MESSAGE_UPDATED=0"
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
  target_email="$(printf '%s' "$user_response" | jq -r '.public_email')"
  [ "$target_email" != "null" ] || {
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
  lookup_ok="$(printf '%s' "$lookup_response" | jq -r '.ok')"
  [ "$lookup_ok" = "true" ] || {
    debug "SLACK_LOOKUP_NOT_OK"
    continue
  }
  slack_lookup_success_count=$((slack_lookup_success_count + 1))

  user_id="$(printf '%s' "$lookup_response" | jq -r '.user.id')"
  [ "$user_id" != "null" ] || {
    debug "SLACK_USER_ID_MISSING"
    continue
  }

  dm_open_body="$(jq -n --arg user_id "$user_id" '{users: $user_id}')"
  dm_open_response="$(slack_post "conversations.open" "$dm_open_body" || true)"
  [ -n "$dm_open_response" ] || {
    debug "SLACK_DM_OPEN_EMPTY"
    continue
  }
  dm_open_ok="$(printf '%s' "$dm_open_response" | jq -r '.ok')"
  [ "$dm_open_ok" = "true" ] || {
    debug "SLACK_DM_OPEN_NOT_OK"
    continue
  }
  dm_channel_id="$(printf '%s' "$dm_open_response" | jq -r '.channel.id')"
  [ "$dm_channel_id" != "null" ] || {
    debug "SLACK_DM_CHANNEL_ID_MISSING"
    continue
  }

  message_body="$(jq -n \
    --arg channel "$dm_channel_id" \
    --arg text "$fallback_text" \
    --arg header_text "$header_text" \
    --arg comment_text "$note" \
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
        }
      ]
    }')"

  case "$action" in
    create)
      post_response="$(slack_post "chat.postMessage" "$message_body" || true)"
      [ -n "$post_response" ] || {
        debug "SLACK_POST_EMPTY"
        continue
      }
      post_ok="$(printf '%s' "$post_response" | jq -r '.ok')"
      [ "$post_ok" = "true" ] || {
        debug "SLACK_POST_NOT_OK"
        continue
      }
      message_sent_count=$((message_sent_count + 1))
      debug "MESSAGE_SENT_OK"
      ;;
    update)
      history_query="channel=$(jq -rn --arg channel "$dm_channel_id" '$channel|@uri')&limit=20"
      history_response="$(slack_get "conversations.history" "$history_query" || true)"
      [ -n "$history_response" ] || {
        debug "SLACK_HISTORY_EMPTY"
        continue
      }
      history_ok="$(printf '%s' "$history_response" | jq -r '.ok')"
      [ "$history_ok" = "true" ] || {
        debug "SLACK_HISTORY_NOT_OK"
        continue
      }
      message_ts="$(printf '%s' "$history_response" | jq -r --arg note_anchor "$note_anchor" '.messages | map(select((.text // "") | contains($note_anchor))) | .[0].ts')"
      [ "$message_ts" != "null" ] || {
        debug "SLACK_MESSAGE_TS_NOT_FOUND"
        continue
      }
      update_body="$(printf '%s' "$message_body" | jq -c --arg ts "$message_ts" '. + {ts: $ts}')"
      update_response="$(slack_post "chat.update" "$update_body" || true)"
      [ -n "$update_response" ] || {
        debug "SLACK_UPDATE_EMPTY"
        continue
      }
      update_ok="$(printf '%s' "$update_response" | jq -r '.ok')"
      [ "$update_ok" = "true" ] || {
        debug "SLACK_UPDATE_NOT_OK"
        continue
      }
      message_updated_count=$((message_updated_count + 1))
      debug "MESSAGE_UPDATED_OK"
      ;;
  esac
done

printf 'PARTICIPANTS_COUNT=%s\n' "$participants_count"
printf 'PUBLIC_EMAIL_FOUND=%s\n' "$public_email_found_count"
printf 'SLACK_LOOKUP_SUCCESS=%s\n' "$slack_lookup_success_count"
printf 'MESSAGE_SENT=%s\n' "$message_sent_count"
printf 'MESSAGE_UPDATED=%s\n' "$message_updated_count"
