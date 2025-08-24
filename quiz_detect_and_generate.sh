#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C.UTF-8

# ===== Config =====
REPO_SSH="git@github.com:Campus-Molndal-JINH24/lectures.git"
BRANCH_HINT="main"
SUBROOT="8_cloud_integration/lectures"
STATE_DIR="/var/lib/quiz_sync"
STATE_FILE="${STATE_DIR}/seen.txt"
GENERATOR="$HOME/scripts/quiz_md_to_sql_V2.sh"     # your generator (non-interactive)  <-- changed
COURSE_NAME="molnintegration"              # course name used in SQL
NOTIFY_EMAIL="79davand@gafe.molndal.se"    # empty string => no email

# ===== UI =====
ok(){   printf '  \033[32m[OK]\033[0m  %s\n'   "$1"; }
fail(){ printf '  \033[31m[FAIL]\033[0m %s\n' "$1" >&2; }
warn(){ printf '  \033[33m[WARN]\033[0m %s\n' "$1" >&2; }

# ===== Helpers =====

# Determine next QUESTION_NUMBER based on existing SQL under ~/quiz_out
next_start_from_sql(){
  local course="$1" max=0 n f
  [ -d "$HOME/quiz_out" ] || { echo 1; return; }
  ls -1 "$HOME/quiz_out"/quiz_*.sql "$HOME/quiz_out"/quiz_import.sql 2>/dev/null | while read -r f; do
    n="$(
      awk -v course="$course" '
        {
          # match lines like:    ('\''molnintegration'\'', 11, '...')
          if (match($0, /^[[:space:]]*\('\''([^'\'']*)'\'',[[:space:]]*([0-9]+)/, m)) {
            if (m[1] == course) {
              if (m[2] + 0 > max) max = m[2] + 0
            }
          }
        }
        END { print (max==0?0:max) }
      ' "$f" 2>/dev/null
    )"
    [ -n "${n:-}" ] || n=0
    [ "$n" -gt "$max" ] && max="$n"
  done
  echo $((max + 1))
}

# Count questions in a lesson dir (lines starting with N. or N) )
count_questions_in_dir(){
  local dir="$1" cnt
  cnt="$(
    find "$dir" -type f -name '*quiz.md' -print0 \
    | xargs -0 awk '/^[[:space:]]*[0-9]+[.)][[:space:]]+/ {c++} END{print c+0}' 2>/dev/null || echo 0
  )"
  echo "${cnt:-0}"
}

# ===== Pre-flight =====
[ -x "$GENERATOR" ] || { fail "Generator missing/not executable: $GENERATOR"; exit 1; }
for b in git sha256sum find sort join awk sed grep ssh date xargs; do
  command -v "$b" >/dev/null 2>&1 || { fail "Missing dependency: $b"; exit 1; }
done
[ -d "$STATE_DIR" ] || { sudo mkdir -p "$STATE_DIR"; sudo chown "$USER":"$USER" "$STATE_DIR"; }

# ===== Clone repo (SSH, with fallbacks) =====
export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519'
WORKDIR="$(mktemp -d)"; CLONE_DIR="${WORKDIR}/repo"

try_clone(){ local br="${1-}"
  rm -rf "$CLONE_DIR" 2>/dev/null || true
  if [ -n "$br" ]; then git clone --depth 1 --filter=blob:none --branch "$br" "$REPO_SSH" "$CLONE_DIR" >/dev/null 2>&1
  else git clone --depth 1 --filter=blob:none "$REPO_SSH" "$CLONE_DIR" >/dev/null 2>&1; fi
}
if    try_clone "$BRANCH_HINT"; then USED="$BRANCH_HINT"
elif  try_clone master;        then USED="master"
elif  try_clone "";            then USED="$(git -C "$CLONE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo default)"
else  fail "Could not clone via SSH"; exit 1
fi
ok "Cloned branch '${USED}'"

TARGET="$CLONE_DIR/$SUBROOT"
[ -d "$TARGET" ] || { fail "Path does not exist in repo: $SUBROOT"; exit 1; }
ok "Target directory: $TARGET"

# ===== Snapshot (path<TAB>hash) =====
SNAP="${WORKDIR}/snapshot.tsv"
( cd "$TARGET"
  find . -type f -name '*quiz.md' -print0 \
  | sort -z \
  | while IFS= read -r -d '' f; do
      printf '%s\t%s\n' "${f#./}" "$(sha256sum "$f" | awk '{print $1}')"
    done
) > "$SNAP"

if [ ! -s "$STATE_FILE" ]; then
  cp "$SNAP" "$STATE_FILE"
  ok "Initialized state (first run) → $STATE_FILE"
  echo "No changes to generate on first run."
  exit 0
fi

STATE_SORTED="${WORKDIR}/state.tsv"
sort -u -t $'\t' -k1,1 "$STATE_FILE" > "$STATE_SORTED"

cut -f1 "$SNAP"         | sort -u > "${WORKDIR}/snap.paths"
cut -f1 "$STATE_SORTED" | sort -u > "${WORKDIR}/state.paths"

comm -23 "${WORKDIR}/snap.paths" "${WORKDIR}/state.paths" > "${WORKDIR}/new.txt"
join -t $'\t' -j 1 "$STATE_SORTED" "$SNAP" > "${WORKDIR}/joined.tsv" || true
awk -F '\t' 'NF>=3 && $2 != $3 {print $1}' "${WORKDIR}/joined.tsv" > "${WORKDIR}/modified.txt"

NEW_N="$(wc -l < "${WORKDIR}/new.txt" | tr -d ' ')"
MOD_N="$(wc -l < "${WORKDIR}/modified.txt" | tr -d ' ')"

echo "== Changes to generate =="
echo "NEW:      ${NEW_N}"
[ "$NEW_N" -gt 0 ] && nl -ba "${WORKDIR}/new.txt"
echo
echo "MODIFIED: ${MOD_N}"
[ "$MOD_N" -gt 0 ] && nl -ba "${WORKDIR}/modified.txt"
echo

if [ "$NEW_N" -eq 0 ] && [ "$MOD_N" -eq 0 ]; then
  ok "No new/modified quizzes."
  exit 0
fi

# ===== Affected lesson directories (unique parent dirs) =====
CHANGED_DIRS="${WORKDIR}/changed_dirs.txt"
cat "${WORKDIR}/new.txt" "${WORKDIR}/modified.txt" 2>/dev/null | sed '/^$/d' \
| awk -F'/' 'NF>=1{NF=NF-1; OFS="/"; print $0}' \
| sort -u > "$CHANGED_DIRS"

# ===== Compute next start number from previous SQL =====
NEXT_NUM="$(next_start_from_sql "$COURSE_NAME")"
ok "Starting numbering from ${NEXT_NUM} (auto-detected from existing SQL)"

# ===== Run generator per lesson dir and bump NEXT_NUM =====
OUT_PARENT="$HOME/quiz_out"
mkdir -p "$OUT_PARENT"
TS="$(date +%Y%m%d_%H%M%S)"
i=0

while IFS= read -r rel_dir; do
  [ -z "$rel_dir" ] && continue
  i=$((i+1))
  GH_URL="https://github.com/Campus-Molndal-JINH24/lectures/tree/${USED}/${SUBROOT}/${rel_dir}"
  OUT_FILE="${OUT_PARENT}/quiz_${TS}_${i}.sql"
  QCOUNT="$(count_questions_in_dir "$TARGET/$rel_dir")"
  [ -z "$QCOUNT" ] && QCOUNT=0
  echo "==> ${rel_dir}: ${QCOUNT} questions → start ${NEXT_NUM}"

  "$GENERATOR" --url "$GH_URL" --course "$COURSE_NAME" --start "$NEXT_NUM" --output "$OUT_FILE"

  if [ -n "${NOTIFY_EMAIL:-}" ]; then
    {
      echo "Source: $GH_URL"
      echo "File:   $OUT_FILE"
      echo
      echo "----- SQL START -----"
      cat "$OUT_FILE"
      echo "----- SQL END -----"
    } | s-nail -s "New quiz SQL: $(basename "$OUT_FILE")" "$NOTIFY_EMAIL" \
      || warn "Could not send email for $OUT_FILE"
  fi

  NEXT_NUM=$((NEXT_NUM + QCOUNT))
done < "$CHANGED_DIRS"

# ===== Update state (ack) =====
cp "$SNAP" "$STATE_FILE"
ok "State updated → $STATE_FILE"
ok "Done. Generated SQL in: $OUT_PARENT"
