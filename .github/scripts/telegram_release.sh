#!/usr/bin/env bash
# Announces a release on the Telegram channel of venera-v.
#
# Usage: telegram_release.sh v2.0.2 [directory of installers]
#
# Reads RELEASE_BODY (the release notes, Markdown) and RELEASE_URL from the
# environment, and the bot token from TELEGRAM_BOT_TOKEN. The bot must be an
# admin of the channel that may post messages. With a directory, the
# installers in it follow the message, as albums of 2 to 10 files.
#
# TELEGRAM_API is the Bot API server, https://api.telegram.org by default.
# That one takes files of up to 50 MB; a local server started with --local
# takes up to 2000 MB.
#
# With DRY_RUN=1 it prints the requests instead of sending them.
set -euo pipefail

CHANNEL="@VeneraV_Updates"
API="${TELEGRAM_API:-https://api.telegram.org}"
tag="${1:?tag}"
dir="${2:-}"

# Telegram shows plain text here: drop tables and the headings they leave
# empty, and unwrap Markdown emphasis, code and links.
text=$(RELEASE_BODY="${RELEASE_BODY:-}" perl -CS -MEncode -0777 -e '
  my $s = Encode::decode("UTF-8", $ENV{RELEASE_BODY} // "");
  $s =~ s/\r//g;
  $s =~ s/^\|.*\n?//mg;
  $s =~ s/^##+ *([^\n]*)\n\s*(?=^##|\z)//mg;
  $s =~ s/^##+ *//mg;
  $s =~ s/\*\*(.+?)\*\*/$1/g;
  $s =~ s/`([^`]*)`/$1/g;
  $s =~ s/\[([^\]]+)\]\(([^)]+)\)/$1 ($2)/g;
  $s =~ s/\n{3,}/\n\n/g;
  $s =~ s/^\s+|\s+$//g;
  # Telegram allows 4096 characters.
  $s = substr($s, 0, 3500) . "…" if length($s) > 3500;
  print $s;
')

message="venera-v ${tag} 发布了"
if [ -n "$text" ]; then
  message+=$'\n\n'"$text"
fi
message+=$'\n\n'"下载：${RELEASE_URL:?RELEASE_URL}"

payload=$(MESSAGE="$message" CHANNEL="$CHANNEL" perl -MEncode -MJSON::PP -e '
  print JSON::PP->new->utf8->canonical->encode({
    chat_id => $ENV{CHANNEL},
    text => Encode::decode("UTF-8", $ENV{MESSAGE}),
  });
')

# Installers by platform: Android, iOS, Windows, macOS, Linux.
files=()
if [ -n "$dir" ]; then
  shopt -s nullglob
  for pattern in "*.apk" "*.ipa" "*.exe" "*.zip" "*.dmg" "*.deb" "*.zst" "*.AppImage"; do
    for f in "$dir"/$pattern; do
      files+=("$f")
    done
  done
  shopt -u nullglob
fi

# An album takes 2 to 10 files: the files go in albums of even sizes (11
# files as 6 and 5, not 10 and 1), and a single file on its own.
albums=()
left=${#files[@]}
for ((count = (left + 9) / 10; count > 0; count--)); do
  size=$(((left + count - 1) / count))
  albums+=("$((${#files[@]} - left)):$size")
  left=$((left - size))
done

# The method that sends [count] files.
method_for() {
  if [ "$1" -eq 1 ]; then echo sendDocument; else echo sendMediaGroup; fi
}

if [ "${DRY_RUN:-}" = 1 ]; then
  echo "POST $API/bot<token>/sendMessage"
  echo "$payload"
  for album in "${albums[@]}"; do
    group=("${files[@]:${album%:*}:${album#*:}}")
    echo "POST $API/bot<token>/$(method_for ${#group[@]})"
    printf '  %s\n' "${group[@]}"
  done
  exit 0
fi

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is not set}"
# A pasted token often carries a space or line break.
token=$(printf '%s' "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
if [[ ! "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  echo "TELEGRAM_BOT_TOKEN does not look like a bot token (digits:letters)" >&2
  exit 1
fi

# Sends a request to the Bot API, failing unless Telegram answers ok.
call() {
  local method="$1"
  shift
  local response
  if ! response=$(curl -sS --max-time 900 "$@" "$API/bot${token}/$method"); then
    echo "Could not reach the Bot API for $method" >&2
    return 1
  fi
  if ! echo "$response" | grep -q '"ok":true'; then
    echo "Telegram did not take $method: $response" >&2
    return 1
  fi
}

call sendMessage -H "Content-Type: application/json" -d "$payload"
echo "Announced ${tag} on ${CHANNEL}"

for album in "${albums[@]}"; do
  group=("${files[@]:${album%:*}:${album#*:}}")
  args=(--form-string "chat_id=$CHANNEL")
  if [ ${#group[@]} -eq 1 ]; then
    call sendDocument "${args[@]}" -F "document=@${group[0]}"
  else
    media="["
    for j in "${!group[@]}"; do
      [ "$j" -gt 0 ] && media+=","
      media+="{\"type\":\"document\",\"media\":\"attach://file$j\"}"
      args+=(-F "file$j=@${group[$j]}")
    done
    media+="]"
    call sendMediaGroup "${args[@]}" --form-string "media=$media"
  fi
  echo "Sent $(printf '%s ' "${group[@]##*/}")"
done
