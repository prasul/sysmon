#!/bin/bash
# ═══════════════════════════════════════════════
#   SYSTEM MONITOR DASHBOARD — AI Prasul :-P
# ═══════════════════════════════════════════════

R="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

RED="\033[38;5;196m"
RED_S="\033[38;5;203m"
GREEN="\033[38;5;82m"
GREEN_S="\033[38;5;114m"
YELLOW="\033[38;5;220m"
CYAN="\033[38;5;45m"
CYAN_S="\033[38;5;80m"
BLUE_D="\033[38;5;27m"
MAGENTA="\033[38;5;171m"
ORANGE="\033[38;5;214m"
WHITE="\033[38;5;255m"
GRAY="\033[38;5;244m"
DGRAY="\033[38;5;238m"
BG_HEADER="\033[48;5;18m"
BG_ALERT="\033[48;5;52m"
BLINK="\033[5m"

ACCESSLOG_PATH="/home/nginx/domains/*/log/access.log"
ERRORLOG_PATH="/home/nginx/domains/*/log/error.log"
SLOWLOG="/var/log/php-fpm/www-slow.log"
IP_STATE_FILE="/tmp/ip_counts.state"
touch "$IP_STATE_FILE"
FILE_CACHE="/tmp/recent_file_changes.cache"
LAST_FILE_SCAN=0
SCAN_INTERVAL=900  # 900 seconds = 15 minutes
ERRLOG_STATE="/tmp/nginx_error_counts.state"  # persists per-domain error counts across refreshes
touch "$ERRLOG_STATE"
MYSQL_QPS_STATE="/tmp/mysql_qps.state"        # tracks query count between refreshes for QPS delta
touch "$MYSQL_QPS_STATE"
PHPFPM_STATUS_URL="http://127.0.0.1/status"   # adjust if your fpm status page is on a different path/port

# ══════════════════════════════════════════════════════
#  LAYOUT CONFIG — all column math in one place
#  Change numbers here and everything adjusts globally
# ══════════════════════════════════════════════════════
TW=$(tput cols 2>/dev/null || echo 120)
HALF=$(( TW / 2 - 1 ))

# Two-column layout widths (must fit inside HALF)
COL_PROC_N=4       # process rank number
COL_PROC_NAME=26   # process name
COL_PROC_PCT=6     # cpu/mem %

COL_NET_STATE=24   # network state
COL_NET_COUNT=6    # connection count

COL_IP_HITS=10     # ip hit count
COL_IP_ADDR=28     # ip address
COL_IP_DELTA=8     # delta indicator

COL_URL_HITS=8     # url hit count
COL_URL_DOM=22     # domain
COL_URL_PATH=28    # url path

COL_WL_HITS=6      # wp-login hits
COL_WL_DOM=22      # domain
COL_WL_IP=26       # ip
COL_WL_METHOD=8    # method
COL_WL_TIME=14     # timestamp

COL_SLOW_COUNT=8   # slowlog count
COL_SLOW_DOM=26    # domain
COL_SLOW_PLUGIN=22 # plugin name

COL_VEL_HITS=6     # velocity hits
COL_VEL_DOM=22     # domain
COL_VEL_IP=28      # ip
COL_VEL_STATUS=8   # status

COL_FC_DOM=20      # file change domain
COL_FC_TYPE=7      # plugin/theme label
COL_FC_COUNT=6     # number of files changed
COL_FC_PLUGIN=28   # plugin or theme folder name
# last modified (most recent) gets the remainder

# Nginx error log columns (full-width block)
COL_ERR_DOM=22     # domain name
COL_ERR_TIME=20    # timestamp of latest entry
COL_ERR_DELTA=6    # +N new errors since last refresh
COL_ERR_CLIENT=18  # client IP
COL_ERR_REQ=24     # request path
# snippet (error message) gets the remainder

# PHP-FPM pool columns (two-column block, left side)
COL_FPM_POOL=20    # pool name
COL_FPM_ACT=7      # active workers
COL_FPM_IDLE=6     # idle workers
COL_FPM_MAX=6      # max children
COL_FPM_QUEUE=7    # queue depth
COL_FPM_STATUS=12  # status label

# MySQL health columns (two-column block, right side)
COL_MH_LABEL=18    # metric label
COL_MH_VAL=14      # metric value

# Disk I/O columns (full-width block)
COL_IO_DEV=10      # device name
COL_IO_READ=10     # read KB/s
COL_IO_WRITE=10    # write KB/s
COL_IO_AWAIT=12    # await ms
COL_IO_UTIL=8      # utilisation %

# MySQL full-width query wrap (full width minus indent and border char)
COL_MYSQL_ID=8
COL_MYSQL_DB=22
COL_MYSQL_TIME=6
COL_MYSQL_STATE=16
COL_MYSQL_QUERY=$(( TW - COL_MYSQL_ID - COL_MYSQL_DB - COL_MYSQL_TIME - COL_MYSQL_STATE - 10 ))
[ "$COL_MYSQL_QUERY" -lt 40 ] && COL_MYSQL_QUERY=40

# ── Full-width line ───────────────────────────────
hline() {
    local char="${1:- }" color="${2:-$DGRAY}"
    local line=""
    for ((i=0; i<TW; i++)); do line+="$char"; done
    printf "${color}%s${R}\n" "$line"
}

# ── Column divider character ──────────────────────
VBAR="${DGRAY}|${R}"

# ── Color a percentage value (integer-safe) ───────
color_pct() {
    local val="${1%.*}" hi="${2:-50}" med="${3:-20}"
    if   [ "${val:-0}" -ge "$hi"  ] 2>/dev/null; then printf "${RED}${BOLD}"
    elif [ "${val:-0}" -ge "$med" ] 2>/dev/null; then printf "${ORANGE}"
    else printf "${GREEN_S}"
    fi
}

# ══════════════════════════════════════════════════
# render_two_cols FILE_LEFT FILE_RIGHT
#   Merges two files side-by-side, ANSI-aware padding
# ══════════════════════════════════════════════════
render_two_cols() {
    local left="$1" right="$2"
    local col_w="$HALF"

    awk -v col="$col_w" '
    function strip(s,    r) {
        r = s
        while (match(r, /\033\[[0-9;]*m/)) {
            r = substr(r,1,RSTART-1) substr(r,RSTART+RLENGTH)
        }
        return r
    }
    function pad_to(s, w,    pl, spaces) {
        pl = length(strip(s))
        spaces = w - pl
        if (spaces < 0) spaces = 0
        return s sprintf("%" spaces "s", "")
    }
    BEGIN { i = 0; j = 0 }
    FILENAME == ARGV[1] { left[++i]  = $0; next }
    FILENAME == ARGV[2] { right[++j] = $0 }
    END {
        n = (i > j) ? i : j
        for (k = 1; k <= n; k++) {
            l = (k <= i) ? left[k]  : ""
            r = (k <= j) ? right[k] : ""
            printf "%s  \033[38;5;238m│\033[0m  %s\n", pad_to(l, col), r
        }
    }
    ' "$left" "$right"
}

# ════════════════════════════════════════════════
FRAME=$(mktemp)
while true; do

    # ── All output goes into $FRAME first ────────
    # clear + cat happen together at the end so the
    # terminal never shows a partial/scrolling render
    {
    NOW=$(date "+%A, %d %b %Y  %H:%M:%S")
    HOST=$(hostname -s 2>/dev/null || echo "server")
    UPTIME_STR=$(uptime -p 2>/dev/null | sed 's/up //' || uptime | awk '{print $3,$4}' | tr -d ',')
    LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | xargs)

    # ══════════════════════════════════════════════
    #  DISK WARNING — check before header renders
    #  Shows a full-width alert banner if any mount
    #  is at or above 98% used
    # ══════════════════════════════════════════════
    DISK_WARN=""
    while read -r pct mount; do
        pct_num="${pct%%%}"   # strip the % sign
        if [ "${pct_num:-0}" -ge 98 ] 2>/dev/null; then
            DISK_WARN="${DISK_WARN}${mount} at ${pct}  "
        fi
    done < <(df -h --output=pcent,target 2>/dev/null | awk 'NR>1 && $1!="Use%"')

    # ── HEADER ───────────────────────────────────
    hline '═' "$BLUE_D"
    hdr_left="  🖥  SYSTEM MONITOR DASHBOARD"
    pad=$(( TW - ${#hdr_left} - ${#NOW} - 4 ))
    [ "$pad" -lt 1 ] && pad=1
    printf "${BG_HEADER}${CYAN}${BOLD}%s%*s${YELLOW}%s  ${R}\n" "$hdr_left" "$pad" "" "$NOW"
    hline '═' "$BLUE_D"

    # ── DISK WARNING BANNER (shown only when triggered) ──
    if [ -n "$DISK_WARN" ]; then
        hline '█' "$BG_ALERT"
        # Center the warning text
        warn_txt="  ⚠  CRITICAL DISK USAGE:  ${DISK_WARN}"
        warn_pad=$(( (TW - ${#warn_txt}) / 2 ))
        [ "$warn_pad" -lt 0 ] && warn_pad=0
        printf "${BG_ALERT}${RED}${BOLD}${BLINK}%*s%s%*s${R}\n" \
            "$warn_pad" "" "$warn_txt" "$warn_pad" ""
        hline '█' "$BG_ALERT"
    fi

    printf "\n"
    printf "  ${DGRAY}◆ HOST:${R}  ${WHITE}${BOLD}%-24s${R}  " "$HOST"
    printf "${DGRAY}◆ UPTIME:${R} ${WHITE}${BOLD}%-26s${R}  " "$UPTIME_STR"
    printf "${DGRAY}◆ LOAD AVG:${R} ${WHITE}${BOLD}%s${R}\n\n" "$LOAD_AVG"

    # ══════════════════════════════════════════════
    #  SYSTEM PRESSURE BAR — always visible
    #  Sits directly below host line so it's the
    #  first thing eyes land on during an incident.
    #  Sources: /proc/stat (iowait), /proc/meminfo
    #  (available/swap), vmstat (swap I/O),
    #  ps D-state count
    # ══════════════════════════════════════════════
    {
        # ── CPU iowait % ──────────────────────────
        # Read two snapshots 0.3s apart for an accurate delta
        read_cpu1=$(awk '/^cpu / {print $5, $6}' /proc/stat 2>/dev/null)
        read_total1=$(awk '/^cpu / {s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat 2>/dev/null)
        sleep 0.3
        read_cpu2=$(awk '/^cpu / {print $5, $6}' /proc/stat 2>/dev/null)
        read_total2=$(awk '/^cpu / {s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat 2>/dev/null)
        IOWAIT_PCT=$(awk -v c1="$read_cpu1" -v t1="$read_total1" \
                         -v c2="$read_cpu2" -v t2="$read_total2" '
            BEGIN {
                split(c1,a1," "); split(c2,a2," ")
                diowait = a2[1] - a1[1]
                dtotal  = t2 - t1
                if (dtotal > 0) printf "%.0f", (diowait/dtotal)*100
                else print "0"
            }')

        # ── Memory: available and total ───────────
        MEM_AVAIL=$(awk '/^MemAvailable:/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null)
        MEM_TOTAL=$(awk '/^MemTotal:/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null)
        MEM_USED=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.0f", ((t-a)/t)*100}' /proc/meminfo 2>/dev/null)

        # ── Swap: used and I/O rates ──────────────
        SWAP_USED=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{
            used=(t-f)/1024; printf "%.0fM", used}' /proc/meminfo 2>/dev/null)
        SWAP_TOTAL=$(awk '/^SwapTotal:/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)

        # Swap I/O: read two vmstat snapshots
        SWAP_IN=0; SWAP_OUT=0
        if command -v vmstat &>/dev/null; then
            vmstat_line=$(vmstat 1 2 2>/dev/null | tail -1)
            SWAP_IN=$(echo  "$vmstat_line" | awk '{print $7}')
            SWAP_OUT=$(echo "$vmstat_line" | awk '{print $8}')
        fi

        # ── D-state (uninterruptible sleep) count ─
        DSTATE=$(ps -eo stat 2>/dev/null | grep -c '^D' | tr -d '[:space:]')
        DSTATE=$(( ${DSTATE:-0} + 0 ))

        # ── OOM kills in last 100 dmesg lines ─────
        OOM_COUNT=$(dmesg 2>/dev/null | tail -n 100 | grep -c "Out of memory\|oom-kill" | tr -d '[:space:]')
        OOM_COUNT=$(( ${OOM_COUNT:-0} + 0 ))

        # ── Sanitize all numerics — strip newlines/spaces that break [ -ge ] ──
        IOWAIT_PCT=$(( ${IOWAIT_PCT:-0} + 0 ))
        MEM_USED=$(( ${MEM_USED:-0} + 0 ))
        SWAP_IN=$(( ${SWAP_IN:-0} + 0 ))
        SWAP_OUT=$(( ${SWAP_OUT:-0} + 0 ))

        # ── Colour helpers ────────────────────────
        iowait_col="${GREEN_S}"
        [ "$IOWAIT_PCT" -ge 20 ] && iowait_col="${ORANGE}"
        [ "$IOWAIT_PCT" -ge 50 ] && iowait_col="${RED}${BOLD}"

        mem_col="${GREEN_S}"
        [ "$MEM_USED" -ge 80 ] && mem_col="${ORANGE}"
        [ "$MEM_USED" -ge 95 ] && mem_col="${RED}${BOLD}"

        swap_col="${GREEN_S}"
        [ "$SWAP_OUT" -ge 10 ] && swap_col="${ORANGE}"
        [ "$SWAP_OUT" -ge 50 ] && swap_col="${RED}${BOLD}"

        dstate_col="${GREEN_S}"
        [ "$DSTATE" -ge 3  ] && dstate_col="${ORANGE}"
        [ "$DSTATE" -ge 10 ] && dstate_col="${RED}${BOLD}"

        oom_col="${GREEN_S}"
        [ "$OOM_COUNT" -ge 1 ] && oom_col="${RED}${BOLD}${BLINK}"

        printf "${CYAN}${BOLD}  ▶  SYSTEM PRESSURE${R}"

        # Alert label if things look bad
        if [ "$IOWAIT_PCT" -ge 50 ] || [ "$MEM_USED" -ge 95 ] || \
           [ "$DSTATE"     -ge 10 ] || [ "$OOM_COUNT" -ge 1 ]; then
            printf "  ${BG_ALERT}${RED}${BOLD}${BLINK} ⚠ HIGH LOAD DETECTED ${R}"
        fi
        printf "\n"

        printf "  ${DGRAY}CPU iowait:${R} ${iowait_col}${BOLD}%-6s%%${R}  " "${IOWAIT_PCT:-0}"
        printf "${DGRAY}Mem used:${R} ${mem_col}${BOLD}%-4s%%${R} ${DGRAY}(${R}${WHITE}${MEM_AVAIL}G avail / ${MEM_TOTAL}G${R}${DGRAY})${R}  "
        printf "${DGRAY}Swap:${R} ${swap_col}${BOLD}%-6s${R}  "  "${SWAP_USED}"
        printf "${DGRAY}Swap I/O in/out:${R} ${swap_col}${BOLD}%s/%s KB/s${R}  " "${SWAP_IN:-0}" "${SWAP_OUT:-0}"
        printf "${DGRAY}D-state procs:${R} ${dstate_col}${BOLD}%s${R}  " "${DSTATE:-0}"
        printf "${DGRAY}OOM kills:${R} ${oom_col}${BOLD}%s${R}\n" "${OOM_COUNT:-0}"
    }
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 1: CPU (left) | Memory (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — CPU
    {
        printf "${YELLOW}${BOLD}  ▶  TOP CPU PROCESSES${R}\n"
        printf "  ${DGRAY}%-${COL_PROC_N}s %-${COL_PROC_NAME}s %s${R}\n" "#" "PROCESS" "CPU%"
        printf "  ${DGRAY}%-${COL_PROC_N}s %-${COL_PROC_NAME}s %s${R}\n" "──" "─────────────────────────" "────"
        n=0
        ps -eo comm,%cpu --sort=-%cpu 2>/dev/null | awk 'NR>1&&NR<=7{print $1,$2}' | \
        while read -r proc pct; do
            n=$((n+1))
            pc=$(color_pct "$pct" 50 20)
            printf "  ${GRAY}%2d${R}  ${WHITE}%-${COL_PROC_NAME}.${COL_PROC_NAME}s${R}  ${pc}%s%%${R}\n" \
                "$n" "$proc" "$pct"
        done
    } > "$C1"

    # RIGHT — Memory
    {
        printf "${YELLOW}${BOLD}  ▶  TOP MEMORY PROCESSES${R}\n"
        printf "  ${DGRAY}%-${COL_PROC_N}s %-${COL_PROC_NAME}s %s${R}\n" "#" "PROCESS" "MEM%"
        printf "  ${DGRAY}%-${COL_PROC_N}s %-${COL_PROC_NAME}s %s${R}\n" "──" "─────────────────────────" "────"
        m=0
        ps -eo comm,%mem --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=7{print $1,$2}' | \
        while read -r proc pct; do
            m=$((m+1))
            mc=$(color_pct "$pct" 20 10)
            printf "  ${GRAY}%2d${R}  ${WHITE}%-${COL_PROC_NAME}.${COL_PROC_NAME}s${R}  ${mc}%s%%${R}\n" \
                "$m" "$proc" "$pct"
        done
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 2: Top URLs (left) | Top IPs (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — Top URLs
    {
        printf "${YELLOW}${BOLD}  ▶  TOP URLs BY DOMAIN${R}\n"
        printf "  ${DGRAY}%-${COL_URL_HITS}s %-${COL_URL_DOM}s %s${R}\n" "HITS" "DOMAIN" "URL"
        printf "  ${DGRAY}%-${COL_URL_HITS}s %-${COL_URL_DOM}s %s${R}\n" "──────" "────────────────────" "──────────────────────────"
        url_temp=$(mktemp)
        for logfile in $ACCESSLOG_PATH; do
            [ -f "$logfile" ] || continue
            domain=$(echo "$logfile" | awk -F'/' '{print $5}')
            awk -v dom="$domain" '{print dom, $7}' "$logfile" >> "$url_temp" 2>/dev/null
        done
        sort "$url_temp" | uniq -c | sort -nr | head -10 | \
        awk -v o="${ORANGE}" -v g="${GREEN_S}" -v c="${CYAN_S}" -v r="${R}" \
            -v h="$COL_URL_HITS" -v d="$COL_URL_DOM" -v u="$COL_URL_PATH" \
            '{printf "  %s%-"h"s%s  %s%-"d"."d"s%s  %s%-"u"."u"s%s\n", o,$1,r, g,$2,r, c,$3,r}'
        rm -f "$url_temp"
    } > "$C1"

    # RIGHT — Top IPs & Traffic Spikes
    {
        printf "${CYAN}${BOLD}  ▶  TOP IPs & TRAFFIC SPIKES${R}\n"
        printf "  ${DGRAY}%-${COL_IP_HITS}s %-${COL_IP_ADDR}s %s${R}\n" "HITS" "IP ADDRESS" "Δ"
        printf "  ${DGRAY}%-${COL_IP_HITS}s %-${COL_IP_ADDR}s %s${R}\n" "────────" "────────────────────────────" "──────"
        new_state=$(mktemp)
        awk '{print $1}' $ACCESSLOG_PATH 2>/dev/null | sort | uniq -c | sort -nr | head -8 | \
        while read -r count ip; do
            [ -z "$ip" ] && continue
            echo "$ip $count" >> "$new_state"
            prev=$(grep "^$ip " "$IP_STATE_FILE" 2>/dev/null | awk '{print $2}')
            if [ -n "$prev" ]; then
                diff=$((count - prev))
                if   [ "$diff" -gt 100 ]; then chg="${RED}${BOLD}↑+${diff}${R}"
                elif [ "$diff" -gt   0 ]; then chg="${ORANGE}↑+${diff}${R}"
                elif [ "$diff" -lt   0 ]; then chg="${GREEN_S}↓${diff}${R}"
                else chg="${DGRAY}—${R}"
                fi
            else
                chg="${CYAN}${BOLD}NEW${R}"
            fi
            printf "  ${ORANGE}%-${COL_IP_HITS}s${R}  ${CYAN_S}%-${COL_IP_ADDR}.${COL_IP_ADDR}s${R}  %b\n" \
                "$count" "$ip" "$chg"
        done
        mv "$new_state" "$IP_STATE_FILE" 2>/dev/null
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 3: Network (left) | WP-Login (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    #FILE CHANGES — left

    {
        CUR_TIME=$(date +%s)

        if (( CUR_TIME - LAST_FILE_SCAN > SCAN_INTERVAL )); then

            # Pass 1 — collect every changed file into a flat tsv:
            #   domain <TAB> type <TAB> plugin <TAB> mod_datetime
            find /home/nginx/domains/*/public/wp-content/{plugins,themes} \
                -maxdepth 3 -mmin -1440 -type f \
                \( -name "*.php" -o -name "*.js" \) 2>/dev/null \
            | while IFS= read -r filepath; do
                dom=$(echo   "$filepath" | cut -d'/' -f5)
                ftype=$(echo "$filepath" | cut -d'/' -f8)
                plugin=$(echo "$filepath" | cut -d'/' -f9)
                mod=$(stat -c "%y" "$filepath" 2>/dev/null | cut -d'.' -f1)
                printf "%s\t%s\t%s\t%s\n" "$dom" "$ftype" "$plugin" "$mod"
            done \
            | awk -F'\t' '
            {
                key = $1 "\t" $2 "\t" $3    # domain + type + plugin name
                count[key]++
                # keep the latest mod time per plugin
                if ($4 > latest[key]) latest[key] = $4
            }
            END {
                for (k in count) {
                    split(k, p, "\t")
                    # p[1]=domain  p[2]=type  p[3]=plugin
                    printf "%s\t%s\t%s\t%d\t%s\n", p[1], p[2], p[3], count[k], latest[k]
                }
            }' \
            | sort -t$'\t' -k5,5r \
            | head -12 > "$FILE_CACHE"

            LAST_FILE_SCAN=$CUR_TIME
        fi

        printf "${ORANGE}${BOLD}  ▶  FILE CHANGES (Last 24h — Scanned every 15m)${R}\n"
        printf "  ${DGRAY}%-${COL_FC_DOM}s %-${COL_FC_TYPE}s %-${COL_FC_COUNT}s %-${COL_FC_PLUGIN}s %s${R}\n" \
            "DOMAIN" "TYPE" "FILES" "PLUGIN / THEME" "LAST MODIFIED"
        printf "  ${DGRAY}%-${COL_FC_DOM}s %-${COL_FC_TYPE}s %-${COL_FC_COUNT}s %-${COL_FC_PLUGIN}s %s${R}\n" \
            "$(printf '─%.0s' $(seq 1 $COL_FC_DOM))" \
            "$(printf '─%.0s' $(seq 1 $COL_FC_TYPE))" \
            "$(printf '─%.0s' $(seq 1 $COL_FC_COUNT))" \
            "$(printf '─%.0s' $(seq 1 $COL_FC_PLUGIN))" \
            "───────────────────"

        if [ -s "$FILE_CACHE" ]; then
            while IFS=$'\t' read -r dom ftype plugin count modtime; do
                if [ "$ftype" = "plugins" ]; then
                    t_col="\033[38;5;45m";  t_label="Plugin"
                else
                    t_col="\033[38;5;171m"; t_label="Theme"
                fi

                # Colour the file count: orange if > 5 files changed, green otherwise
                if [ "${count:-0}" -gt 5 ] 2>/dev/null; then
                    c_col="\033[38;5;214m"
                else
                    c_col="\033[38;5;82m"
                fi

                printf "  \033[38;5;114m%-${COL_FC_DOM}.${COL_FC_DOM}s\033[0m ${t_col}%-${COL_FC_TYPE}s\033[0m ${c_col}%-${COL_FC_COUNT}s\033[0m \033[38;5;220m%-${COL_FC_PLUGIN}.${COL_FC_PLUGIN}s\033[0m \033[38;5;244m%s\033[0m\n" \
                    "$dom" "$t_label" "$count" "$plugin" "$modtime"
            done < "$FILE_CACHE"
        else
            printf "  ${GRAY}${DIM}(no changes detected in the last 24h)${R}\n"
        fi
    } > "$C1"

   

    # RIGHT — WP-Login
    {
        wplogin_raw=$(grep "wp-login.php" $ACCESSLOG_PATH 2>/dev/null)
        if [ -n "$wplogin_raw" ]; then
            printf "${RED}${BOLD}${BLINK}  ⚠  WP-LOGIN.PHP DETECTED${R}\n"
            printf "  ${DGRAY}%-${COL_WL_HITS}s %-${COL_WL_DOM}s %-${COL_WL_IP}s %-${COL_WL_METHOD}s %s${R}\n" \
                "HITS" "DOMAIN" "IP" "METHOD" "LAST SEEN"
            printf "  ${DGRAY}%-${COL_WL_HITS}s %-${COL_WL_DOM}s %-${COL_WL_IP}s %-${COL_WL_METHOD}s %s${R}\n" \
                "────" "────────────────────" "──────────────────────────" "──────" "──────────────"
            echo "$wplogin_raw" | awk '{
                match($0, /access\.log:/);
                if (RSTART > 0) {
                    filename = substr($0, 1, RSTART+9);
                    split(filename, p, "/"); domain = p[5];
                    content = substr($0, RSTART+10);
                    split(content, parts, " "); ip = parts[1];
                    ts = $4; gsub(/\[/, "", ts);
                    method = $6; gsub(/\042/, "", method);
                    print domain, ip, ts, method
                }
            }' | sort -k1,1 -k2,2 -k3,3r | awk '
                !seen[$1,$2,$4]++ { count[$1,$2,$4]=1; last_ts[$1,$2,$4]=$3 }
                seen[$1,$2,$4]>1  { count[$1,$2,$4]++ }
                END {
                    for (i in count) {
                        split(i, sep, SUBSEP)
                        print count[i], sep[1], sep[2], sep[3], last_ts[i]
                    }
                }' | sort -nr | head -8 | \
            while read -r hits domain ip method ts; do
                [ "$method" = "POST" ] && mfmt="${RED}${BOLD}[POST]${R}" || mfmt="${GREEN_S}[GET] ${R}"
                printf "  ${ORANGE}%-${COL_WL_HITS}s${R}  ${GREEN_S}%-${COL_WL_DOM}.${COL_WL_DOM}s${R}  ${CYAN_S}%-${COL_WL_IP}.${COL_WL_IP}s${R}  %b  ${GRAY}%s${R}\n" \
                    "$hits" "$domain" "$ip" "$mfmt" "$ts"
            done
        else
            printf "${GREEN_S}${BOLD}  ✔  WP-LOGIN.PHP${R}\n"
            printf "  ${GREEN_S}No suspicious activity detected.${R}\n"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 5: LIVE URL HITS — FULL WIDTH
    #
    #  Aggregates the current-minute access logs
    #  by URL + IP, shows hit count and Δ change
    #  since the last refresh — same concept as
    #  Top URLs but scoped to the live 20s window
    # ════════════════════════════════════════════
    {
        LIVE_STATE="/tmp/live_velocity.state"
        LIVE_URL_STATE="/tmp/live_url_ip.state"   # persists URL+IP counts between refreshes
        NEW_LIVE_STATE=$(mktemp)
        CUR_MIN=$(date "+%d/%b/%Y:%H:%M")

        # Column widths — URL gets whatever is left
        COL_LV_HITS=6
        COL_LV_DELTA=10
        COL_LV_IP=18
        COL_LV_DOM=20
        COL_LV_METHOD=6
        COL_LV_STATUS=6
        COL_LV_URL=$(( TW - COL_LV_HITS - COL_LV_DELTA - COL_LV_IP - COL_LV_DOM - COL_LV_METHOD - COL_LV_STATUS - 16 ))
        [ "$COL_LV_URL" -lt 24 ] && COL_LV_URL=24

        printf "${CYAN}${BOLD}  ▶  LIVE TRAFFIC  ${DGRAY}(current minute window: %s)${R}\n" "$CUR_MIN"

        # Collect current-minute lines: domain  ip  method  url  status
        for log in $ACCESSLOG_PATH; do
            [ -f "$log" ] || continue
            dom=$(echo "$log" | awk -F'/' '{print $5}')
            tail -n 500 "$log" | grep "$CUR_MIN" | \
                awk -v d="$dom" '{
                    ip=$1
                    meth=$6; gsub(/\042/,"",meth)   # strip quotes
                    url=$7
                    status=$9
                    print d, ip, meth, url, status
                }' >> "$NEW_LIVE_STATE"
        done

        if [ -s "$NEW_LIVE_STATE" ]; then

            # ── Section 1: IP + Domain velocity summary ──────────────────
            # Aggregate by domain+ip only — shows who is hitting hardest
            # and how their count changed since last refresh
            COL_VS_HITS=6
            COL_VS_DOM=24
            COL_VS_IP=18
            COL_VS_DELTA=12
            # remaining width split across extra columns
            COL_VS_PAD=$(( TW - COL_VS_HITS - COL_VS_DOM - COL_VS_IP - COL_VS_DELTA - 12 ))

            printf "\n  ${CYAN}${DIM}▸  TOP IPs THIS MINUTE${R}  ${DGRAY}domain · ip · hits · Δ since last refresh${R}\n"
            printf "  ${DGRAY}%-${COL_VS_HITS}s  %-${COL_VS_DOM}s  %-${COL_VS_IP}s  %s${R}\n" \
                "HITS" "DOMAIN" "IP" "Δ CHANGE"
            printf "  ${DGRAY}%-${COL_VS_HITS}s  %-${COL_VS_DOM}s  %-${COL_VS_IP}s  %s${R}\n" \
                "──────" "$(printf '─%.0s' $(seq 1 $COL_VS_DOM))" \
                "$(printf '─%.0s' $(seq 1 $COL_VS_IP))" "────────────"

            # Build velocity state file path for IP+domain deltas
            LIVE_VEL_STATE="/tmp/live_vel_domip.state"

            awk '{print $1, $2}' "$NEW_LIVE_STATE" | \
            sort | uniq -c | sort -nr | head -10 | \
            while read -r count dom ip; do
                [ -z "$ip" ] && continue

                state_key="${dom}|${ip}"
                prev=$(grep "^${state_key}=" "$LIVE_VEL_STATE" 2>/dev/null | cut -d'=' -f2)
                prev=$(( ${prev:-0} + 0 ))
                count=$(( ${count:-0} + 0 ))

                if [ "$prev" -eq 0 ]; then
                    delta="${ORANGE}${BOLD}NEW${R}"
                else
                    diff=$(( count - prev ))
                    if   [ "$diff" -gt 5 ]; then delta="${RED}${BOLD}↑ +${diff}${R}"
                    elif [ "$diff" -gt 0 ]; then delta="${ORANGE}↑ +${diff}${R}"
                    elif [ "$diff" -lt 0 ]; then delta="${GREEN_S}↓ ${diff}${R}"
                    else                          delta="${DGRAY}  —${R}"
                    fi
                fi

                echo "${state_key}=${count}" >> "${LIVE_VEL_STATE}.new"

                printf "  ${ORANGE}%-${COL_VS_HITS}s${R}  " "$count"
                printf "${GREEN_S}%-${COL_VS_DOM}.${COL_VS_DOM}s${R}  " "$dom"
                printf "${CYAN_S}%-${COL_VS_IP}.${COL_VS_IP}s${R}  "   "$ip"
                printf "%b\n" "$delta"
            done

            mv "${LIVE_VEL_STATE}.new" "$LIVE_VEL_STATE" 2>/dev/null

            # ── Section 2: URL detail table ───────────────────────────────
            printf "\n  ${CYAN}${DIM}▸  URL BREAKDOWN${R}  ${DGRAY}url · ip · method · status · Δ${R}\n"
            printf "  ${DGRAY}%-${COL_LV_HITS}s  %-${COL_LV_DELTA}s  %-${COL_LV_DOM}s  %-${COL_LV_IP}s  %-${COL_LV_METHOD}s  %-${COL_LV_URL}s  %s${R}\n" \
                "HITS" "Δ CHANGE" "DOMAIN" "IP" "METH" "URL" "ST"
            printf "  ${DGRAY}%-${COL_LV_HITS}s  %-${COL_LV_DELTA}s  %-${COL_LV_DOM}s  %-${COL_LV_IP}s  %-${COL_LV_METHOD}s  %-${COL_LV_URL}s  %s${R}\n" \
                "──────" "──────────" \
                "$(printf '─%.0s' $(seq 1 $COL_LV_DOM))" \
                "$(printf '─%.0s' $(seq 1 $COL_LV_IP))" \
                "──────" \
                "$(printf '─%.0s' $(seq 1 $COL_LV_URL))" \
                "──"

            # Aggregate by domain+ip+method+url+status, count hits, keep last status
            # Output: count  domain  ip  method  url  status
            sort "$NEW_LIVE_STATE" | awk '
            {
                key = $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5
                count[key]++
            }
            END {
                for (k in count) {
                    print count[k] "\t" k
                }
            }' | sort -t$'\t' -k1,1rn | head -20 | \

            while IFS=$'\t' read -r hits dom ip meth url status; do
                [ -z "$url" ] && continue

                # ── Delta vs previous refresh ─────
                state_key="${dom}|${ip}|${url}"
                prev=$(grep "^${state_key}=" "$LIVE_URL_STATE" 2>/dev/null | cut -d'=' -f2)
                prev=$(( ${prev:-0} + 0 ))
                hits=$(( ${hits:-0} + 0 ))

                if [ "$prev" -eq 0 ]; then
                    delta="${ORANGE}${BOLD}NEW${R}"
                else
                    diff=$(( hits - prev ))
                    if   [ "$diff" -gt 0 ]; then delta="${RED}${BOLD}↑ +${diff}${R}"
                    elif [ "$diff" -lt 0 ]; then delta="${GREEN_S}↓ ${diff}${R}"
                    else                          delta="${DGRAY}  —${R}"
                    fi
                fi

                # Save updated count for next cycle
                # Use a temp file to avoid reading/writing same file mid-loop
                echo "${state_key}=${hits}" >> "${LIVE_URL_STATE}.new"

                # ── Colour: method ────────────────
                case "$meth" in
                    POST|PUT|DELETE) mc="${RED_S}" ;;
                    GET)             mc="${CYAN_S}" ;;
                    *)               mc="${GRAY}" ;;
                esac

                # ── Colour: HTTP status ───────────
                case "${status:0:1}" in
                    5) sc="${RED}${BOLD}" ;;
                    4) sc="${ORANGE}" ;;
                    3) sc="${YELLOW}" ;;
                    *)  sc="${GREEN_S}" ;;
                esac

                # ── Truncate URL to column width ──
                if [ "${#url}" -gt "$COL_LV_URL" ]; then
                    url="${url:0:$(( COL_LV_URL - 1 ))}…"
                fi

                printf "  ${ORANGE}%-${COL_LV_HITS}s${R}  " "$hits"
                printf "%-${COL_LV_DELTA}b  "               "$delta"
                printf "${GREEN_S}%-${COL_LV_DOM}.${COL_LV_DOM}s${R}  " "$dom"
                printf "${CYAN_S}%-${COL_LV_IP}.${COL_LV_IP}s${R}  "   "$ip"
                printf "${mc}%-${COL_LV_METHOD}s${R}  "                 "$meth"
                printf "${YELLOW}%-${COL_LV_URL}s${R}  "               "$url"
                printf "${sc}%s${R}\n"                                   "$status"

            done

            # Rotate state file atomically
            mv "${LIVE_URL_STATE}.new" "$LIVE_URL_STATE" 2>/dev/null

        else
            printf "  ${GRAY}${DIM}(no traffic in current minute window — waiting...)${R}\n"
        fi

        rm -f "$NEW_LIVE_STATE"
    }
    hline '─' "$DGRAY"

        # ════════════════════════════════════════════
    #  BLOCK 9: NGINX ERROR LOG MONITOR — FULL WIDTH
    #
    #  Reads the last 200 lines of each domain's
    #  error.log, groups by error type + request,
    #  shows delta (+N) vs previous refresh cycle,
    #  and highlights the client IP and snippet.
    # ════════════════════════════════════════════
    {
        # Compute snippet column width from what's left after fixed columns
        COL_ERR_SNIPPET=$(( TW - COL_ERR_DOM - COL_ERR_TIME - COL_ERR_DELTA - COL_ERR_CLIENT - COL_ERR_REQ - 16 ))
        [ "$COL_ERR_SNIPPET" -lt 30 ] && COL_ERR_SNIPPET=30

        printf "${RED_S}${BOLD}  ▶  NGINX ERROR LOG MONITOR${R}\n"
        printf "  ${DGRAY}%-${COL_ERR_DOM}s %-${COL_ERR_TIME}s %-${COL_ERR_DELTA}s %-${COL_ERR_CLIENT}s %-${COL_ERR_REQ}s %s${R}\n" \
            "DOMAIN" "LAST SEEN" "Δ NEW" "CLIENT IP" "REQUEST" "ERROR SNIPPET"
        printf "  ${DGRAY}%-${COL_ERR_DOM}s %-${COL_ERR_TIME}s %-${COL_ERR_DELTA}s %-${COL_ERR_CLIENT}s %-${COL_ERR_REQ}s %s${R}\n" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_DOM))" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_TIME))" \
            "──────" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_CLIENT))" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_REQ))" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_SNIPPET))"

        NEW_ERR_STATE=$(mktemp)
        found_any=0

        for errlog in $ERRORLOG_PATH; do
            [ -f "$errlog" ] || continue

            # Extract domain from path: /home/nginx/domains/DOMAIN/log/error.log
            domain=$(echo "$errlog" | cut -d'/' -f5)

            # Parse the last 200 lines — each line format:
            # 2026/02/25 00:11:51 [error] PID#TID: *ID MESSAGE, client: IP, server: DOMAIN, request: "METHOD PATH PROTO", host: "HOST"
            tail -n 200 "$errlog" 2>/dev/null | awk '
            /\[error\]/ {
                # ── Timestamp ──────────────────────────────────
                ts = $1 " " $2

                # ── Error snippet: everything after the *ID ────
                # Field 5 onwards is the message; strip the *NNN prefix
                snippet = ""
                for (i=5; i<=NF; i++) snippet = snippet " " $i
                sub(/^ \*[0-9]+ /, "", snippet)

                # ── Client IP ──────────────────────────────────
                client = ""
                if (match(snippet, /client: ([0-9.]+|[0-9a-f:]+)/, arr)) {
                    client = arr[1]
                } else {
                    # fallback: find "client: X.X.X.X" manually
                    n = split(snippet, parts, ", ")
                    for (j=1; j<=n; j++) {
                        if (parts[j] ~ /^client:/) { client = parts[j]; sub(/^client: /,"",client); break }
                    }
                }

                # ── Request path ───────────────────────────────
                req = ""
                if (match(snippet, /request: "([^"]+)"/, arr2)) {
                    req = arr2[1]
                    # trim to METHOD + PATH only, drop HTTP version
                    sub(/ HTTP\/[0-9.]+$/, "", req)
                } else {
                    n2 = split(snippet, parts2, ", ")
                    for (j2=1; j2<=n2; j2++) {
                        if (parts2[j2] ~ /^request:/) { req = parts2[j2]; sub(/^request: "/,"",req); sub(/"$/,"",req); break }
                    }
                }

                # ── Core error message (strip trailing metadata) ─
                core = snippet
                sub(/, client:.*$/, "", core)
                gsub(/^[ \t]+|[ \t]+$/, "", core)

                # ── Key: domain + core error (dedup similar errors) ─
                key = client "|" req "|" core
                if (!(key in seen)) {
                    seen[key] = 1
                    latest_ts[key] = ts
                    client_ip[key]  = client
                    request[key]    = req
                    message[key]    = core
                } else {
                    if (ts > latest_ts[key]) latest_ts[key] = ts
                }
                total[key]++
            }
            END {
                for (k in seen) {
                    printf "%s\t%s\t%d\t%s\t%s\n", latest_ts[k], client_ip[k], total[k], request[k], message[k]
                }
            }' | sort -t$'\t' -k1,1r | head -6 | \
            while IFS=$'\t' read -r ts client cnt req msg; do
                found_any=1

                # Build state key for delta calculation
                state_key="${domain}|${client}|${req}"
                echo "${state_key}=${cnt}" >> "$NEW_ERR_STATE"

                # Delta vs last refresh
                prev_cnt=$(grep "^${state_key}=" "$ERRLOG_STATE" 2>/dev/null | cut -d'=' -f2)
                if [ -n "$prev_cnt" ] && [ "$prev_cnt" -ne "$cnt" ] 2>/dev/null; then
                    diff=$(( cnt - prev_cnt ))
                    if [ "$diff" -gt 0 ]; then
                        delta="${RED}${BOLD}+${diff}${R}"
                        age_label="${RED}${BOLD}NEW${R}"
                    else
                        delta="${GREEN_S}${diff}${R}"
                        age_label="${GRAY}OLD${R}"
                    fi
                elif [ -z "$prev_cnt" ]; then
                    delta="${ORANGE}${BOLD}NEW${R}"
                    age_label="${ORANGE}${BOLD}NEW${R}"
                else
                    delta="${DGRAY}—${R}"
                    age_label="${DGRAY}—${R}"
                fi

                # Truncate message to snippet column width
                msg_short="${msg:0:$COL_ERR_SNIPPET}"

                printf "  \033[38;5;114m%-${COL_ERR_DOM}.${COL_ERR_DOM}s\033[0m" "$domain"
                printf " \033[38;5;244m%-${COL_ERR_TIME}.${COL_ERR_TIME}s\033[0m" "$ts"
                printf " %-${COL_ERR_DELTA}b" "$delta"
                printf " \033[38;5;203m%-${COL_ERR_CLIENT}.${COL_ERR_CLIENT}s\033[0m" "$client"
                printf " \033[38;5;45m%-${COL_ERR_REQ}.${COL_ERR_REQ}s\033[0m" "$req"
                printf " \033[38;5;255m%s\033[0m\n" "$msg_short"
            done
        done

        # Rotate state file so next refresh has fresh deltas
        [ -s "$NEW_ERR_STATE" ] && mv "$NEW_ERR_STATE" "$ERRLOG_STATE" || rm -f "$NEW_ERR_STATE"

        if [ "$found_any" -eq 0 ]; then
            printf "  ${GREEN_S}${DIM}(no errors found in nginx logs)${R}\n"
        fi
    }
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 6: MYSQL ACTIVE PROCESSES — FULL WIDTH
    #
    #  MySQL gets its own full-width block because
    #  query text is too long for a half-column.
    #  Each process shows a summary line then the
    #  full query wrapped to terminal width.
    # ════════════════════════════════════════════
    {
        printf "${MAGENTA}${BOLD}  ▶  MYSQL ACTIVE PROCESSES${R}\n"
        printf "  ${DGRAY}%-${COL_MYSQL_ID}s %-${COL_MYSQL_DB}s %-${COL_MYSQL_TIME}s %-${COL_MYSQL_STATE}s %s${R}\n" \
            "ID" "DATABASE" "TIME" "STATE" "QUERY PREVIEW"
        printf "  ${DGRAY}%-${COL_MYSQL_ID}s %-${COL_MYSQL_DB}s %-${COL_MYSQL_TIME}s %-${COL_MYSQL_STATE}s %s${R}\n" \
            "────────" "──────────────────────" "──────" "────────────────" "$(printf '─%.0s' $(seq 1 $COL_MYSQL_QUERY))"

        mysql_out=$(mysql --batch --silent -e "
            SELECT
                ID,
                IFNULL(DB, 'system')    AS DB,
                TIME,
                IFNULL(STATE, '')       AS STATE,
                IFNULL(INFO, '')        AS INFO
            FROM information_schema.PROCESSLIST
            WHERE COMMAND != 'Sleep'
              AND INFO IS NOT NULL
            ORDER BY TIME DESC
            LIMIT 8;" 2>/dev/null)

        if [ -z "$mysql_out" ]; then
            printf "  ${GRAY}${DIM}(no active queries)${R}\n"
        else
            # Use process substitution so IFS=$'\t' applies cleanly per-line
            while IFS=$'\t' read -r id db time state query; do
                [[ "$id" == "ID" ]] && continue
                [ -z "$id" ]        && continue

                # Time colouring: red ≥ 5s, orange otherwise
                if [ "${time:-0}" -ge 5 ] 2>/dev/null; then
                    tc="\033[38;5;196m"   # red
                else
                    tc="\033[38;5;214m"   # orange
                fi

                # ── Summary line: ID  DB  TIME  STATE ──────────────
                printf "  \033[38;5;244m%-${COL_MYSQL_ID}s\033[0m" "$id"
                printf " \033[38;5;82m%-${COL_MYSQL_DB}.${COL_MYSQL_DB}s\033[0m" "$db"
                printf " ${tc}%-${COL_MYSQL_TIME}s\033[0m" "${time}s"
                printf " \033[38;5;45m%-${COL_MYSQL_STATE}.${COL_MYSQL_STATE}s\033[0m\n" "$state"

                # ── Full query, word-wrapped at COL_MYSQL_QUERY ──────
                # Normalize whitespace: collapse newlines/tabs to single space
                clean_query=$(echo "$query" | tr '\n\t' '  ' | tr -s ' ')
                echo "$clean_query" | fold -s -w "$COL_MYSQL_QUERY" | \
                while IFS= read -r qline; do
                    printf "  \033[38;5;240m│\033[0m \033[38;5;255m%s\033[0m\n" "$qline"
                done

                # ── Per-process separator ────────────────────────────
                printf "  \033[38;5;237m%s\033[0m\n" \
                    "$(printf '╌%.0s' $(seq 1 $(( TW - 4 ))))"
            done <<< "$mysql_out"
        fi
    }
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 7: Network Connections (left) | PHP SLOWLOG (right)
    #  File cache is scanned every SCAN_INTERVAL
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

     # LEFT — Network Connections
    {
        printf "${CYAN}${BOLD}  ▶  NETWORK CONNECTIONS${R}\n"
        printf "  ${DGRAY}%-${COL_NET_STATE}s %s${R}\n" "STATE" "COUNT"
        printf "  ${DGRAY}%-${COL_NET_STATE}s %s${R}\n" "───────────────────────" "─────"
        netstat -ant 2>/dev/null | awk '{print $6}' \
            | grep -v 'State\|Foreign\|^$' \
            | sort | uniq -c | sort -nr | head -8 | \
        while read -r cnt state; do
            [ -z "$state" ] && continue
            case "$state" in
                ESTABLISHED) sc="${GREEN}" ;;
                SYN_RECV)    sc="${RED}${BOLD}" ;;
                TIME_WAIT)   sc="${ORANGE}" ;;
                CLOSE_WAIT)  sc="${YELLOW}" ;;
                LISTEN)      sc="${CYAN_S}" ;;
                FIN_WAIT*)   sc="${MAGENTA}" ;;
                *)           sc="${GRAY}" ;;
            esac
            printf "  ${sc}%-${COL_NET_STATE}s${R}  ${WHITE}%s${R}\n" "$state" "$cnt"
        done
        syn_count=$(netstat -ant 2>/dev/null | grep -c "SYN_RECV" | head -n1)
        : "${syn_count:=0}"
        if [ "$syn_count" -gt 20 ]; then
            printf "\n  ${RED}${BOLD}${BLINK}⚠ SYN FLOOD: %s conns!${R}\n" "$syn_count"
        fi
    } > "$C1"

    # RIGHT — PHP Slowlog (paired with file changes — both are "what changed" views)
    {
        if [ -f "$SLOWLOG" ]; then
            printf "${RED_S}${BOLD}  ▶  PHP SLOWLOG — TOP CULPRITS${R}\n"
            printf "  ${DGRAY}%-${COL_SLOW_COUNT}s %-${COL_SLOW_DOM}s %s${R}\n" "COUNT" "DOMAIN" "PLUGIN"
            printf "  ${DGRAY}%-${COL_SLOW_COUNT}s %-${COL_SLOW_DOM}s %s${R}\n" "──────" "────────────────────────" "──────────────────────"
            grep "wp-content/plugins/" "$SLOWLOG" | \
            sed -rn 's/.*\/domains\/([^/]+)\/.*plugins\/([^/ ]+).*/\1 \2/p' | \
            sort | uniq -c | sort -nr | head -8 | \
            awk -v o="${ORANGE}" -v g="${GREEN_S}" -v rs="${RED_S}" -v r="${R}" \
                -v sc="$COL_SLOW_COUNT" -v sd="$COL_SLOW_DOM" -v sp="$COL_SLOW_PLUGIN" \
                '{printf "  %s%-"sc"s%s  %s%-"sd"."sd"s%s  %s%-"sp"."sp"s%s\n", o,$1,r, g,$2,r, rs,$3,r}'
        else
            printf "${GRAY}${DIM}  ▶  PHP SLOWLOG${R}\n"
            printf "  ${GRAY}${DIM}(slowlog not found at configured path)${R}\n"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 8: DISK I/O — FULL WIDTH
    #
    #  Uses /proc/diskstats with a 1s delta to
    #  compute real KB/s read+write and await ms.
    #  Only shows physical disks (sd*, nvme*, vd*).
    #  Falls back to iostat if available.
    # ════════════════════════════════════════════
    {
        printf "${YELLOW}${BOLD}  ▶  DISK I/O${R}\n"
        printf "  ${DGRAY}%-${COL_IO_DEV}s %-${COL_IO_READ}s %-${COL_IO_WRITE}s %-${COL_IO_AWAIT}s %-${COL_IO_UTIL}s %s${R}\n" \
            "DEVICE" "READ/s" "WRITE/s" "AWAIT(ms)" "UTIL%" "STATUS"
        printf "  ${DGRAY}%-${COL_IO_DEV}s %-${COL_IO_READ}s %-${COL_IO_WRITE}s %-${COL_IO_AWAIT}s %-${COL_IO_UTIL}s %s${R}\n" \
            "──────────" "──────────" "──────────" "────────────" "────────" "──────────"

        if command -v iostat &>/dev/null; then
            # iostat -x: extended stats, 2 samples 1s apart, show only the second
            iostat -xk 1 2 2>/dev/null | awk '
            /^(sd|nvme|vd|xvd|hd)[a-z0-9]/ {
                dev=$1; rkbs=$6; wkbs=$7; await=$10; util=$NF
                # colour thresholds
                uc="\033[38;5;82m"
                if (util+0 >= 50) uc="\033[38;5;214m"
                if (util+0 >= 85) uc="\033[38;5;196m\033[1m"
                ac="\033[38;5;82m"
                if (await+0 >= 20) ac="\033[38;5;214m"
                if (await+0 >= 100) ac="\033[38;5;196m\033[1m"

                st="✔ OK"
                stc="\033[38;5;82m"
                if (util+0 >= 85 || await+0 >= 100) { st="⚠ HIGH"; stc="\033[38;5;196m\033[1m" }
                else if (util+0 >= 50 || await+0 >= 20) { st="▲ BUSY"; stc="\033[38;5;214m" }

                printf "  \033[38;5;255m%-10s\033[0m %s%-9s\033[0m %s%-9s\033[0m %s%-10s\033[0m %s%-8s\033[0m %b%s\033[0m\n",
                    dev,
                    "\033[38;5;45m",  sprintf("%.0fK", rkbs),
                    "\033[38;5;171m", sprintf("%.0fK", wkbs),
                    ac, sprintf("%.1fms", await),
                    uc, sprintf("%.0f%%", util),
                    stc, st
            }' | tail -n +2   # skip first sample (cumulative), keep second (interval)
        else
            # Fallback: /proc/diskstats two-snapshot delta
            snap1=$(awk '/^[ ]*[0-9]+ [0-9]+ (sd|nvme|vd)/ {print $3,$6,$10,$13}' /proc/diskstats 2>/dev/null)
            sleep 1
            snap2=$(awk '/^[ ]*[0-9]+ [0-9]+ (sd|nvme|vd)/ {print $3,$6,$10,$13}' /proc/diskstats 2>/dev/null)

            paste <(echo "$snap1") <(echo "$snap2") | awk '{
                dev=$1
                dr=($6-$2)*512/1024    # sectors→KB
                dw=($7-$3)*512/1024
                dio_ms=($8-$4)         # ms spent in I/O
                # simple util: ms doing I/O in last 1000ms
                util=(dio_ms > 1000) ? 100 : dio_ms/10

                uc="\033[38;5;82m"
                if (util >= 50) uc="\033[38;5;214m"
                if (util >= 85) uc="\033[38;5;196m\033[1m"

                st="✔ OK"; stc="\033[38;5;82m"
                if (util >= 85) { st="⚠ HIGH"; stc="\033[38;5;196m\033[1m" }
                else if (util >= 50) { st="▲ BUSY"; stc="\033[38;5;214m" }

                printf "  \033[38;5;255m%-10s\033[0m \033[38;5;45m%-10s\033[0m \033[38;5;171m%-10s\033[0m \033[38;5;244m%-12s\033[0m %s%-8s\033[0m %b%s\033[0m\n",
                    dev,
                    sprintf("%.0fK/s", dr),
                    sprintf("%.0fK/s", dw),
                    "n/a",
                    uc, sprintf("%.0f%%", util),
                    stc, st
            }'
        fi
    }
    hline '─' "$DGRAY"

        # ════════════════════════════════════════════
    #  BLOCK 4: PHP-FPM Pools (left) | MySQL Health (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — PHP-FPM pool status
    # Reads /proc/net/unix to find fpm socket paths, then
    # queries each pool's status page via cgi-fcgi.
    # Falls back to ps worker count if unreachable.
    {
        printf "${CYAN}${BOLD}  ▶  PHP-FPM POOLS${R}\n"
        printf "  ${DGRAY}%-${COL_FPM_POOL}s %-${COL_FPM_ACT}s %-${COL_FPM_IDLE}s %-${COL_FPM_MAX}s %-${COL_FPM_QUEUE}s %s${R}\n" \
            "POOL" "ACTIVE" "IDLE" "MAX" "QUEUE" "STATUS"
        printf "  ${DGRAY}%-${COL_FPM_POOL}s %-${COL_FPM_ACT}s %-${COL_FPM_IDLE}s %-${COL_FPM_MAX}s %-${COL_FPM_QUEUE}s %s${R}\n" \
            "$(printf '─%.0s' $(seq 1 $COL_FPM_POOL))" "──────" "─────" "─────" "──────" "──────────"

        fpm_found=0

        # Method 1: query status pages via unix sockets using cgi-fcgi
        if command -v cgi-fcgi &>/dev/null; then
            for sock in /var/run/php*.sock /run/php/*.sock /tmp/php*.sock; do
                [ -S "$sock" ] || continue
                pool=$(basename "$sock" .sock | sed 's/php[0-9.-]*-fpm-\?//')
                [ -z "$pool" ] && pool=$(basename "$sock" .sock)

                status_raw=$(SCRIPT_FILENAME=/status SCRIPT_NAME=/status \
                    REQUEST_METHOD=GET cgi-fcgi -bind -connect "$sock" 2>/dev/null)

                active=$(echo "$status_raw" | grep "^active processes:"  | awk '{print $NF}')
                idle=$(echo   "$status_raw" | grep "^idle processes:"    | awk '{print $NF}')
                maxc=$(echo   "$status_raw" | grep "^max children reached" | awk '{print $NF}')
                queue=$(echo  "$status_raw" | grep "^listen queue:"      | awk '{print $NF}')
                maxq=$(echo   "$status_raw" | grep "^max listen queue:"  | awk '{print $NF}')

                [ -z "$active" ] && continue
                fpm_found=1

                total=$(( ${active:-0} + ${idle:-0} ))
                [ "$total" -eq 0 ] && total=1
                pct=$(( ${active:-0} * 100 / total ))

                if   [ "${active:-0}" -ge "${maxc:-999}" ] 2>/dev/null; then
                    st="${RED}${BOLD}⚠ SATURATED${R}"
                elif [ "$pct" -ge 80 ]; then
                    st="${ORANGE}▲ HIGH${R}"
                else
                    st="${GREEN_S}✔ OK${R}"
                fi

                printf "  ${WHITE}%-${COL_FPM_POOL}.${COL_FPM_POOL}s${R} " "$pool"
                printf "${ORANGE}%-${COL_FPM_ACT}s${R} "    "${active:-0}"
                printf "${GRAY}%-${COL_FPM_IDLE}s${R} "     "${idle:-0}"
                printf "${DGRAY}%-${COL_FPM_MAX}s${R} "     "${maxc:-?}"
                printf "${YELLOW}%-${COL_FPM_QUEUE}s${R} "  "${queue:-0}"
                printf "%b\n" "$st"
            done
        fi

        # Method 2: fallback — count php-fpm worker processes via ps
        if [ "$fpm_found" -eq 0 ]; then
            ps -eo comm,stat 2>/dev/null | awk '
            /php-fpm/ || /php[0-9].*-fpm/ {
                if ($2 ~ /^S/) idle++
                else if ($2 ~ /^R/) active++
                total++
            }
            END {
                if (total > 0) {
                    pct = int(active*100/total)
                    st = (pct >= 80) ? "\033[38;5;196mHIGH\033[0m" : "\033[38;5;82m✔ OK\033[0m"
                    printf "  \033[38;5;255m%-20s\033[0m %-7s %-6s %-6s %-7s %b\n",
                        "php-fpm", active+0, idle+0, total, "n/a", st
                } else {
                    print "  \033[38;5;244m(php-fpm not detected or status page unreachable)\033[0m"
                }
            }'
        fi
    } > "$C1"

    # RIGHT — MySQL Health metrics
    # Uses mysqladmin status + SHOW GLOBAL STATUS for key counters.
    # QPS is computed as a delta against the previous refresh so it
    # shows actual queries/sec rather than a lifetime cumulative.
    {
        printf "${MAGENTA}${BOLD}  ▶  MYSQL HEALTH${R}\n"
        printf "  ${DGRAY}%-${COL_MH_LABEL}s %s${R}\n" "METRIC" "VALUE"
        printf "  ${DGRAY}%-${COL_MH_LABEL}s %s${R}\n" "$(printf '─%.0s' $(seq 1 $COL_MH_LABEL))" "──────────────"

        # Fetch all status vars in one query
        mysql_health=$(mysql --batch --silent -e "
            SHOW GLOBAL STATUS WHERE Variable_name IN (
                'Threads_connected','Threads_running','max_used_connections',
                'Questions','Slow_queries','Table_locks_waited',
                'Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests',
                'Innodb_row_lock_waits','Com_select','Com_insert',
                'Com_update','Com_delete','Aborted_connects'
            );
            SHOW VARIABLES WHERE Variable_name = 'max_connections';" 2>/dev/null)

        if [ -z "$mysql_health" ]; then
            printf "  ${GRAY}${DIM}(mysql not accessible)${R}\n"
        else
            get_val() { echo "$mysql_health" | awk -v k="$1" '$1==k{print $2}'; }

            threads_conn=$(get_val "Threads_connected")
            threads_run=$(get_val  "Threads_running")
            max_conn=$(get_val     "max_connections")
            questions=$(get_val    "Questions")
            slow_q=$(get_val       "Slow_queries")
            lock_wait=$(get_val    "Table_locks_waited")
            bp_reads=$(get_val     "Innodb_buffer_pool_reads")
            bp_req=$(get_val       "Innodb_buffer_pool_read_requests")
            row_locks=$(get_val    "Innodb_row_lock_waits")
            aborted=$(get_val      "Aborted_connects")

            # ── QPS delta ─────────────────────────
            prev_q=$(cat "$MYSQL_QPS_STATE" 2>/dev/null || echo 0)
            QPS=0
            if [ -n "$questions" ] && [ "${prev_q:-0}" -gt 0 ] 2>/dev/null; then
                QPS=$(( (questions - prev_q) / 20 ))   # 20s refresh interval
                [ "$QPS" -lt 0 ] && QPS=0
            fi
            echo "${questions:-0}" > "$MYSQL_QPS_STATE"

            # ── InnoDB buffer pool hit rate ────────
            BP_HIT="n/a"
            if [ -n "$bp_req" ] && [ "${bp_req:-0}" -gt 0 ] 2>/dev/null; then
                BP_HIT=$(awk -v r="${bp_reads:-0}" -v req="$bp_req" \
                    'BEGIN{printf "%.1f%%", (1-(r/req))*100}')
            fi

            # ── Colour thresholds ──────────────────
            conn_pct=0
            [ "${max_conn:-0}" -gt 0 ] && conn_pct=$(( ${threads_conn:-0} * 100 / max_conn ))
            conn_col="${GREEN_S}";   [ "$conn_pct" -ge 70 ] && conn_col="${ORANGE}";  [ "$conn_pct" -ge 90 ] && conn_col="${RED}${BOLD}"
            run_col="${GREEN_S}";    [ "${threads_run:-0}" -ge 10 ] && run_col="${ORANGE}"; [ "${threads_run:-0}" -ge 30 ] && run_col="${RED}${BOLD}"
            slow_col="${GREEN_S}";   [ "${slow_q:-0}" -ge 5  ] && slow_col="${ORANGE}"; [ "${slow_q:-0}" -ge 20 ] && slow_col="${RED}${BOLD}"
            lock_col="${GREEN_S}";   [ "${lock_wait:-0}" -ge 1  ] && lock_col="${ORANGE}"; [ "${lock_wait:-0}" -ge 10 ] && lock_col="${RED}${BOLD}"
            bp_num=$(echo "$BP_HIT" | tr -d '%')
            bp_col="${GREEN_S}";     [ "${bp_num:-100}" != "n/a" ] && [ "${bp_num%.*}" -lt 99 ] 2>/dev/null && bp_col="${ORANGE}"
                                     [ "${bp_num:-100}" != "n/a" ] && [ "${bp_num%.*}" -lt 95 ] 2>/dev/null && bp_col="${RED}${BOLD}"
            qps_col="${GREEN_S}";    [ "${QPS:-0}" -ge 500  ] && qps_col="${ORANGE}"; [ "${QPS:-0}" -ge 2000 ] && qps_col="${RED}${BOLD}"

            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${conn_col}%s / %s${R} ${DGRAY}(%s%%)${R}\n" \
                "Connections" "${threads_conn:-?}" "${max_conn:-?}" "$conn_pct"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${run_col}%s${R}\n" \
                "Threads running"  "${threads_run:-?}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${qps_col}%s q/s${R}\n" \
                "QPS (last 20s)"   "${QPS}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${slow_col}%s${R}\n" \
                "Slow queries"     "${slow_q:-?}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${lock_col}%s${R}\n" \
                "Table lock waits" "${lock_wait:-?}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${bp_col}%s${R}\n" \
                "InnoDB hit rate"  "${BP_HIT}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${ORANGE}%s${R}\n" \
                "Row lock waits"   "${row_locks:-?}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${GRAY}%s${R}\n" \
                "Aborted connects" "${aborted:-?}"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"



    # ── FOOTER ───────────────────────────────────
    printf "\n"
    hline '═' "$BLUE_D"
    printf "  ${GRAY}${DIM}Refreshing in ${R}${BOLD}${CYAN}20s${R}  ${DGRAY}•${R}  ${GRAY}${DIM}Ctrl+C to exit${R}\n"
    hline '═' "$BLUE_D"
    printf "\n"

    } > "$FRAME"

    # ── Atomic render — clear and print the complete frame in one shot ──
    # This prevents any partial output appearing during data collection
    clear
    cat "$FRAME"

    sleep 20
done
rm -f "$FRAME"