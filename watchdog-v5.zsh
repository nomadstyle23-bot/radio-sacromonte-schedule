#!/bin/zsh
# Radio Sacromonte station watchdog (v5, 13 Oct 2026) - show scheduler (schedule.txt) that can be updated remotely (schedule-url.txt)
# Keeps Spotify -> Audio Hijack -> Radio Cult on air.
# - Every Spotify/Audio Hijack command has a hard time limit, so a frozen Spotify can't freeze the watchdog.
# - Once a minute it asks Radio Cult whether it can hear us; if it is playing the fallback mix, it fixes it.
# Off switch: if the file OFF-AIR exists in this folder, it does nothing.

DIR="${0:A:h}"
LOG="$DIR/watchdog.log"
PLAYLIST="spotify:playlist:1wHqiQSbGUS7ebTkbiPIrS"   # used when Spotify has to be restarted
INTERVAL=5
STATION_API="https://api.radiocult.fm/api/station/radio-sacromonte-935d2b16/schedule/live"
RC_KEY="pk_bc4603a756114e508c6c50505ba5d2f1"        # public read-only key (same as the website)
FALLBACK_FILE="260428_0030.mp3"                     # the mix Radio Cult plays when it can't hear us
NTFY_TOPIC="rs-station-ec4568d6d6"                  # phone alerts (ntfy app)
SCHED="$DIR/schedule.txt"                           # local show schedule: START URI Name (used if there is no remote copy)
URLFILE="$DIR/schedule-url.txt"                     # one line: web address of the remote schedule (missing/empty = local schedule only)
REMOTE="$DIR/schedule.remote"                       # last good copy of the remote schedule
SLOT_NOW=0

log()    { print -r -- "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; }
notify() {
  osascript -e "display notification \"$1\" with title \"Radio Sacromonte\"" >/dev/null 2>&1 &
  curl -s -m 8 -H "Title: Radio Sacromonte station" -H "Tags: radio" -d "$1" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 &
  # email copy: posted to a form on the website; Netlify emails it (Forms > station-alerts > notifications)
  curl -s -m 8 -X POST --data-urlencode "form-name=station-alerts" --data-urlencode "message=$1" --data-urlencode "time=$(date '+%Y-%m-%d %H:%M:%S')" "https://radiosacromonte.com/" >/dev/null 2>&1 &
}
# run a command but give up after N seconds (stops a frozen app hanging the watchdog)
limit()  { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
sp()     { limit 8 osascript -e "tell application \"Spotify\" to $1" >/dev/null 2>&1; }
ah()     { open -g -b com.rogueamoeba.audiohijack "$DIR/$1" >/dev/null 2>&1; }
spotify_pid() { pgrep -x Spotify | head -1; }

# download the remote schedule (once a minute). Keeps the last good copy if the download fails or the file looks wrong.
fetch_schedule() {
  [[ -s "$URLFILE" ]] || return
  local url="$(head -1 "$URLFILE")" tmp="$REMOTE.tmp"
  if curl -sf -m 6 -H "Cache-Control: no-cache" "$url" -o "$tmp" 2>/dev/null && grep -qE '^[0-9][0-9]:[0-9][0-9] +spotify:' "$tmp"; then
    cmp -s "$tmp" "$REMOTE" 2>/dev/null || log "Schedule: remote schedule updated"
    mv "$tmp" "$REMOTE"; fetch_fail=0
  else
    rm -f "$tmp"; fetch_fail=$((fetch_fail+1))
    (( fetch_fail == 3 )) && log "Schedule: cannot reach the remote schedule - keeping the last copy"
  fi
}
active_sched() { if [[ -s "$REMOTE" ]]; then print -r -- "$REMOTE"; else print -r -- "$SCHED"; fi }

# which show should be on now? sets SLOT_URI / SLOT_NAME (and SLOT_NOW) from the schedule (falls back to PLAYLIST)
# lines:  HH:MM spotify:playlist:ID Name
#         OVERRIDE YYYY-MM-DDTHH:MM spotify:playlist:ID [now] Name   (takes over until that time; "now" = switch straight away)
slot_lookup() {
  local now=$(( 10#$(date +%H)*60 + 10#$(date +%M) )) best=-1 last=-1 line t u n m rest
  local stamp="$(date '+%Y-%m-%dT%H:%M')" file="$(active_sched)"
  local -a f
  SLOT_URI="$PLAYLIST"; SLOT_NAME="Default playlist"; SLOT_NOW=0
  local bu="" bn="" lu="" ln="" ou="" on="" onow=0
  [[ -f "$file" ]] || return
  while IFS= read -r line; do
    [[ "$line" == \#* || -z "${line// }" ]] && continue
    if [[ "$line" == OVERRIDE* ]]; then
      f=(${=line})
      if [[ "${f[3]}" == spotify:* && "${f[2]}" > "$stamp" ]]; then
        ou="${f[3]}"; onow=0; on="${f[4,-1]}"
        if [[ "${f[4]}" == now ]]; then onow=1; on="${f[5,-1]}"; fi
      fi
      continue
    fi
    t="${line%% *}"; rest="${line#* }"; rest="${rest#"${rest%%[! ]*}"}"
    u="${rest%% *}"; n="${rest#* }"; n="${n#"${n%%[! ]*}"}"
    [[ "$t" == [0-9][0-9]:[0-9][0-9] && "$u" == spotify:* ]] || continue
    m=$(( 10#${t%%:*}*60 + 10#${t##*:} ))
    if (( m <= now && m > best )); then best=$m; bu="$u"; bn="$n"; fi
    if (( m > last )); then last=$m; lu="$u"; ln="$n"; fi
  done < "$file"
  if [[ -n "$bu" ]]; then SLOT_URI="$bu"; SLOT_NAME="$bn"
  elif [[ -n "$lu" ]]; then SLOT_URI="$lu"; SLOT_NAME="$ln"; fi   # before first start time = last show of the night
  if [[ -n "$ou" ]]; then SLOT_URI="$ou"; SLOT_NAME="${on:-Override}"; SLOT_NOW=$onow; fi
}
# start the current show's playlist on shuffle
start_slot() {
  slot_lookup
  log "Schedule: starting $SLOT_NAME"
  sp "set shuffling to true"; sp "set repeating to true"
  sp "play track \"$SLOT_URI\""; sleep 1; sp "next track"
  cur_uri="$SLOT_URI"; pending_since=0
  # safety: if the show's playlist won't play, fall back to the default playlist so we stay on air
  sleep 4
  local chk="$(limit 8 osascript -e 'tell application "Spotify" to player state as string' 2>/dev/null)"
  if [[ "$chk" != "playing" && "$SLOT_URI" != "$PLAYLIST" ]]; then
    log "Schedule: $SLOT_NAME would not play (got: '$chk') - falling back to the default playlist"
    notify "Playlist for $SLOT_NAME would not play - using default playlist"
    sp "play track \"$PLAYLIST\""
  fi
}

restart_spotify() {
  log "Restarting Spotify ($1)"; notify "Spotify restarted: $1"
  sp "quit"; sleep 3
  pkill -x Spotify 2>/dev/null; sleep 2
  pkill -9 -x Spotify 2>/dev/null; sleep 1
  open -g -a Spotify; sleep 12
  start_slot; sleep 4
  log "Restarting Audio Hijack session so it re-attaches to Spotify"
  ah restart-session.ahcommand
  last_pid="$(spotify_pid)"; same=0; noread=0
  fb=0; next_station=$((SECONDS+180))   # give it 3 minutes before judging the station again
}

# single instance
PIDFILE="$DIR/watchdog.pid"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Watchdog already running."; exit 0
fi
echo $$ > "$PIDFILE"
trap '[[ "$(cat "$PIDFILE" 2>/dev/null)" == "$$" ]] && rm -f "$PIDFILE"' EXIT
printf '\e]0;Radio Sacromonte watchdog - leave open (minimise is fine)\a'
echo "Radio Sacromonte watchdog v5 is running. Leave this window open - minimise it if you like."
log "Watchdog v5 started (remote schedule)"

last_pos=""; last_trk=""; same=0; noread=0
cur_uri=""; pending_since=0; next_sched=0; dur=0; fetch_fail=0
fetch_schedule
fb=0; fixes=0; next_station=$((SECONDS+60)); next_ah=$((SECONDS+60))
last_pid="$(spotify_pid)"

while true; do
  [[ -f "$LOG" && $(stat -f%z "$LOG") -gt 2000000 ]] && tail -n 5000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  if [[ -e "$DIR/OFF-AIR" ]]; then sleep $INTERVAL; continue; fi
  # maintenance switch: a file called RESTART-WATCHDOG makes it exit; the helper reopens it (new version) within 30 s
  if [[ -e "$DIR/RESTART-WATCHDOG" ]]; then rm -f "$DIR/RESTART-WATCHDOG"; log "Restart requested - exiting so the helper reopens the watchdog"; exit 0; fi
  # test switch: create a file called TEST-FREEZE in this folder to freeze Spotify on purpose
  if [[ -e "$DIR/TEST-FREEZE" ]]; then
    rm -f "$DIR/TEST-FREEZE"; log "TEST: freezing Spotify on purpose"; pkill -STOP -x Spotify
  fi

  # 1. Spotify running?
  pid="$(spotify_pid)"
  if [[ -z "$pid" ]]; then
    log "Spotify is not running"; restart_spotify "it had closed"; sleep $INTERVAL; continue
  fi
  if [[ -n "$last_pid" && "$pid" != "$last_pid" ]]; then
    log "Spotify was restarted (new process) - re-attaching Audio Hijack"
    sleep 3; ah restart-session.ahcommand
  fi
  last_pid="$pid"

  # 2. Spotify state (with a time limit - a frozen Spotify doesn't answer)
  st="$(limit 8 osascript -e 'tell application "Spotify"' -e 'set s to (player state as string)' -e 'set p to player position' -e 'set i to ""' -e 'try' -e 'set i to (id of current track) as string' -e 'end try' -e 'set d to 0' -e 'try' -e 'set d to (duration of current track) div 1000' -e 'end try' -e 'end tell' -e 'return s & "|" & ((p div 1) as integer) & "|" & i & "|" & d' 2>/dev/null)"
  state="${st%%|*}"; rest="${st#*|}"; pos="${rest%%|*}"; rest="${rest#*|}"; trk="${rest%%|*}"; dur="${rest#*|}"
  [[ "$dur" == <-> ]] || dur=0

  case "$state" in
    paused)  noread=0; log "Spotify paused - pressing play"; notify "Spotify paused - resumed"; sp "play"; same=0 ;;
    stopped) noread=0; log "Spotify stopped - starting playlist"; notify "Spotify stopped - restarted playlist"
             start_slot; same=0 ;;
    playing)
      noread=0
      if [[ "$pos" == "$last_pos" && "$trk" == "$last_trk" ]]; then same=$((same+1)); else same=0; fi
      if (( same == 3 )); then log "Stalled at ${pos}s for 15s - pause/play"; sp "pause"; sleep 1; sp "play"
      elif (( same == 6 )); then log "Still stalled - next track"; sp "next track"
      elif (( same >= 9 )); then restart_spotify "frozen on one spot"
      fi
      # show scheduler: switch to the new show's playlist as the current song ends
      if (( SECONDS >= next_sched )); then
        next_sched=$((SECONDS+60)); fetch_schedule; slot_lookup
        if [[ "$SLOT_URI" != "$cur_uri" ]]; then
          (( pending_since == 0 )) && pending_since=$((SECONDS+1)) && log "Schedule: $SLOT_NAME is due - switching at the end of this song"
        else pending_since=0; fi
      fi
      if (( pending_since > 0 )); then
        left=$(( dur - pos ))
        if (( SLOT_NOW )) || (( dur > 0 && left <= 12 )) || [[ -n "$last_trk" && "$trk" != "$last_trk" ]] || (( SECONDS - pending_since > 900 )); then start_slot; same=0; fi
      fi ;;
    *)
      noread=$((noread+1))
      (( noread == 1 )) && log "Spotify not answering"
      if (( noread >= 4 )); then restart_spotify "not answering for 30s"; fi ;;
  esac
  last_pos="$pos"; last_trk="$trk"

  # 3. Audio Hijack session running? (once a minute)
  if (( SECONDS >= next_ah )); then
    next_ah=$((SECONDS+60)); sp "set repeating to true"; ah ensure-running.ahcommand
  fi

  # 4. Can Radio Cult hear us? (once a minute, whatever Spotify says)
  if (( SECONDS >= next_station )); then
    next_station=$((SECONDS+60))
    live="$(curl -s -m 8 -H "x-api-key: $RC_KEY" "$STATION_API" 2>/dev/null)"
    if [[ -n "$live" && "$live" == *"$FALLBACK_FILE"* ]]; then
      fb=$((fb+1))
      if (( fb >= 2 )); then
        fb=0; fixes=$((fixes+1))
        if (( fixes == 1 )); then
          log "Station playing fallback - restarting Audio Hijack session"; notify "Station silent - reconnecting Audio Hijack"
          ah restart-session.ahcommand
        else
          restart_spotify "station still silent after Audio Hijack restart"; fixes=0
        fi
      fi
    elif [[ -n "$live" ]]; then
      (( fb > 0 || fixes > 0 )) && log "Station hearing us again" && notify "Station back on air"
      fb=0; fixes=0
    fi
  fi

  sleep $INTERVAL
done
