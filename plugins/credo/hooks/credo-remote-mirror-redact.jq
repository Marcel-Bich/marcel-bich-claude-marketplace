# credo-remote-mirror-redact.jq - masks secret-looking text in a mirror event (credo item #146).
#
# Input: one {key, window, event} line from credo-remote-mirror.sh. Output: the event
# alone, with every string value masked (summaries, questions, headings, blocker texts,
# replies, identifiers). Run as: jq -c -f credo-remote-mirror-redact.jq
#
# Fail-closed: a jq error prints nothing, and the hook then sends nothing.
#
# Rules, applied in this order:
#   1. auth headers and cookies: Authorization / X-API-Key / Cookie ... value
#   2. Bearer tokens: "Bearer <token>"
#   3. NAME=value or "password: value" where NAME holds token, secret, password, passwd, pwd,
#      api key, credential
#   4. --password / --passwd / --pass / --token / --secret / --api-key with a space value
#   5. -p password of a database or ssh client (mysql, psql, sshpass, mongo, redis-cli ...)
#   6. user:password@host in URLs
#   7. provider token prefixes (ghp_, github_pat_, xox*-, sk-)
#   8. runs of 32 or more letters, digits and + _ = - that hold both a letter and a digit
#      (hex hashes, base64 secrets; plain words, paths and short hashes are left alone)
# Masked parts become "***"; the surrounding text stays readable.

def redact:
  gsub("(?i)(?<p>authorization|x-api-key|api[-_]?key|cookie)(?<s>\\s*[:=]\\s*(?:bearer\\s+|basic\\s+|token\\s+)?)[^\\s\"']+"; "\(.p)\(.s)***")
  | gsub("(?i)(?<p>\\bbearer\\s+)[A-Za-z0-9._~+/=-]+"; "\(.p)***")
  | gsub("(?i)(?<p>[a-z0-9_.-]*(token|secret|passw(or)?d|passwd|pwd|apikey|api[_-]key|credential|private[_-]?key)[a-z0-9_.-]*=)[^\\s\"']+"; "\(.p)***")
  | gsub("(?i)(?<p>\\b(token|secret|passw(or)?d|passwd|api[_-]key)\\s*:\\s*)(?!\\*)[^\\s\"']+"; "\(.p)***")
  | gsub("(?i)(?<p>--?(password|passwd|pass|token|secret|api-?key)\\s+)(?!-)[^\\s\"']+"; "\(.p)***")
  | gsub("(?i)(?<p>\\b(mysql|mariadb|mysqldump|psql|sshpass|mongosh?|redis-cli)\\b[^|;&\\n]*?\\s-p\\s?)(?!-)[^\\s\"']+"; "\(.p)***")
  | gsub("(?<p>://[^/\\s:@]+:)[^/\\s@]+(?=@)"; "\(.p)***")
  | gsub("\\b(?:ghp|gho|ghu|ghs|ghr|github_pat|xox[abprs]|sk)[-_][A-Za-z0-9_-]{12,}"; "***")
  | gsub("(?=[A-Za-z0-9+_=-]*[0-9])(?=[A-Za-z0-9+_=-]*[A-Za-z])[A-Za-z0-9+_=-]{32,}"; "***");

def scrub: walk(if type == "string" then redact else . end);

.event // empty | scrub
