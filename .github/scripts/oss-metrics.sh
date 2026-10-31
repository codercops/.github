#!/usr/bin/env bash
# Prints a Markdown report of how our public repos did in one month.
# Usage: oss-metrics.sh [YYYY-MM]   (defaults to last month, UTC)
# Needs gh (logged in, or GH_TOKEN set), jq and curl. Everything it reads is public.
#
# The question it answers: are people outside our own circle starting to use
# and contribute to the projects? So issues and PRs from the lead maintainer,
# the Triage maintainers and bots are counted apart from everyone else's.
#
# It lists PRs and issues through the REST API rather than search, because
# search has a much lower rate limit.
set -euo pipefail

ORG=codercops
REPOS=(chatcops ogcops toolbelt discord-bot)
LEAD=anurag629
# Keep in sync with the Maintainers table in GOVERNANCE.md.
TRIAGE=(bhushan4work prakashNalla anurag2787 piyusshhjangid srikar-naidu Saifjafri212213)
NPM=(@chatcops/widget @chatcops/server @chatcops/core)

# GNU date on the runner, BSD date on a Mac.
month=${1:-$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m 2>/dev/null || date -u -v1d -v-1d +%Y-%m)}
start="$month-01"
end=$(date -u -d "$start +1 month -1 day" +%F 2>/dev/null || date -u -j -v+1m -v-1d -f %F "$start" +%F)
from="${start}T00:00:00Z"
to="${end}T23:59:59Z"

# gh api, tried up to three times. A long paginated listing now and then
# fails halfway on a dropped connection.
ghr() {
  local i out
  for i in 1 2 3; do
    if out=$(gh api "$@"); then
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
    sleep $((i * 5))
  done
  return 1
}

core=$(printf '%s\n' "$LEAD" "${TRIAGE[@]}" | jq -R 'ascii_downcase' | jq -s .)

echo "## Open source metrics for $month"
echo
echo "Window: $start to $end (UTC). \"Outside\" means anyone except @$LEAD, the Triage maintainers in GOVERNANCE.md, and bots."
echo
echo "| Repo | Stars | Forks | Issues opened (outside) | Issues opened (all) | PRs merged (outside) | PRs merged (maintainers) |"
echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"

all_prs=$(mktemp)
for r in "${REPOS[@]}"; do
  read -r stars forks < <(ghr "repos/$ORG/$r" --jq '"\(.stargazers_count) \(.forks_count)"')

  # Every merged PR in the repo, so returning contributors can be told apart.
  ghr --paginate "repos/$ORG/$r/pulls?state=closed&per_page=100" \
    --jq '.[] | select(.merged_at != null) | {login: .user.login, bot: (.user.type == "Bot"), merged: .merged_at}' \
    >"$all_prs.$r"
  cat "$all_prs.$r" >>"$all_prs"

  read -r prs_out prs_core < <(jq -rs --arg from "$from" --arg to "$to" --argjson core "$core" '
    map(select(.merged >= $from and .merged <= $to and (.bot | not)))
    | [ (map(select((.login | ascii_downcase) as $l | $core | index($l) | not)) | length),
        (map(select((.login | ascii_downcase) as $l | $core | index($l))) | length) ]
    | "\(.[0]) \(.[1])"' "$all_prs.$r")

  # Issues opened in the window. "since" filters on last update, so check the
  # creation date too.
  read -r issues_out issues_all < <(ghr --paginate "repos/$ORG/$r/issues?state=all&since=$from&per_page=100" \
    --jq '.[] | select(.pull_request == null) | {login: .user.login, bot: (.user.type == "Bot"), created: .created_at}' |
    jq -rs --arg from "$from" --arg to "$to" --argjson core "$core" '
      map(select(.created >= $from and .created <= $to))
      | [ (map(select((.bot | not) and ((.login | ascii_downcase) as $l | $core | index($l) | not))) | length), length ]
      | "\(.[0]) \(.[1])"')

  echo "| [$r](https://github.com/$ORG/$r) | $stars | $forks | $issues_out | $issues_all | $prs_out | $prs_core |"
  rm -f "$all_prs.$r"
done

# Everyone but the lead maintainer and bots who got a PR merged this month,
# split by whether they had one merged in any of our repos before.
read -r new returning < <(jq -rs --arg from "$from" --arg to "$to" --arg lead "$LEAD" '
  map(select((.bot | not) and (.login | ascii_downcase) != ($lead | ascii_downcase)))
  | (map(select(.merged < $from) | .login | ascii_downcase) | unique) as $before
  | map(select(.merged >= $from and .merged <= $to) | .login) | unique_by(ascii_downcase)
  | [ (map(select(ascii_downcase as $l | $before | index($l) | not))), (map(select(ascii_downcase as $l | $before | index($l)))) ]
  | map(if length == 0 then "-" else join(",") end) | join(" ")' "$all_prs")
rm -f "$all_prs"
count() { [ "$1" = "-" ] && echo 0 || tr ',' '\n' <<<"$1" | wc -l | tr -d ' '; }
names() { [ "$1" = "-" ] && echo "" || echo " (${1//,/, })"; }

echo
echo "### Contributors with a merged PR"
echo
echo "- New this month: $(count "$new")$(names "$new")"
echo "- Returning: $(count "$returning")$(names "$returning")"

echo
echo "### npm downloads"
echo
for p in "${NPM[@]}"; do
  n=$(curl -fsS "https://api.npmjs.org/downloads/point/$start:$end/$p" | jq -r '.downloads // "n/a"') || n="n/a"
  echo "- \`$p\`: $n"
done
echo
echo "Downloads include CI runs and contributors' own installs, so watch the trend more than the number."
