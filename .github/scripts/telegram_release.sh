#!/usr/bin/env bash
# Announces a release on the Telegram channel of venera-v.
#
# Usage: telegram_release.sh v2.0.2
#
# Reads RELEASE_BODY (the release notes, Markdown) and RELEASE_URL from the
# environment, and the bot token from TELEGRAM_BOT_TOKEN. The bot must be an
# admin of the channel that may post messages. With DRY_RUN=1 it prints the
# request instead of sending it.
set -euo pipefail

CHANNEL="@VeneraV_Updates"
tag="${1:?tag}"

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

if [ "${DRY_RUN:-}" = 1 ]; then
  echo "$payload"
  exit 0
fi

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is not set}"
# A pasted token often carries a space or line break.
token=$(printf '%s' "$TELEGRAM_BOT_TOKEN" | tr -d '[:space:]')
if [[ ! "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  echo "TELEGRAM_BOT_TOKEN does not look like a bot token (digits:letters)" >&2
  exit 1
fi
if ! response=$(curl -sS --max-time 30 -H "Content-Type: application/json" -d "$payload" \
  "https://api.telegram.org/bot${token}/sendMessage"); then
  echo "Could not reach Telegram" >&2
  exit 1
fi
if ! echo "$response" | grep -q '"ok":true'; then
  echo "Telegram did not take the message: $response" >&2
  exit 1
fi
echo "Announced ${tag} on ${CHANNEL}"
