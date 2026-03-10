#!/bin/bash
# ═══════════════════════════════════════════════
#   SYSTEM MONITOR DASHBOARD — AI Prasul :-P
#   v2.0 — arithmetic & formatting bugs fixed
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
FILE_SCAN_TS="/tmp/last_file_scan.ts"
[ -f "$FILE_SCAN_TS" ] || echo 0 > "$FILE_SCAN_TS"
SCAN_INTERVAL=900
ERRLOG_STATE="/tmp/nginx_error_counts.state"
touch "$ERRLOG_STATE"
MYSQL_QPS_STATE="/tmp/mysql_qps.state"
touch "$MYSQL_QPS_STATE"
PHPFPM_STATUS_URL="http://127.0.0.1/status"

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
    local raw="${1:-0}"
    local hi="${2:-50}" med="${3:-20}"
    # Strip decimal part safely
    local val
    val=$(echo "$raw" | tr -d '[:space:]' | sed 's/\..*//')
    [[ "$val" =~ ^-?[0-9]+$ ]] || val=0
    if   [ "$val" -ge "$hi"  ]; then printf "${RED}${BOLD}"
    elif [ "$val" -ge "$med" ]; then printf "${ORANGE}"
    else printf "${GREEN_S}"
    fi
}

# ══════════════════════════════════════════════════
# render_two_cols FILE_LEFT FILE_RIGHT
#   Merges two files side-by-side, ANSI-aware padding.
#   FIX: broadened ANSI strip regex to cover all
#        escape sequences, not just SGR 'm' ones.
# ══════════════════════════════════════════════════
render_two_cols() {
    local left="$1" right="$2"
    local col_w="$HALF"

    awk -v col="$col_w" '
    function strip(s,    r) {
        r = s
        while (match(r, /\033\[[0-9;]*[A-Za-z]/)) {
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
#  EXIT REPORT
# ════════════════════════════════════════════════
generate_report() {
    local RPT="/tmp/monitor_report_$(date '+%Y%m%d_%H%M%S').txt"
    local NOW_FULL=$(date "+%A, %d %b %Y  %H:%M:%S")
    local HOST=$(hostname -s 2>/dev/null || echo "server")
    local LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local UPTIME_S=$(uptime -p 2>/dev/null | sed 's/up //')

    {
    echo "════════════════════════════════════════════════════════════════"
    echo "  SERVER PERFORMANCE REPORT"
    echo "  Generated : ${NOW_FULL}"
    echo "  Host      : ${HOST}"
    echo "  Uptime    : ${UPTIME_S}"
    echo "  Load avg  : ${LOAD}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    echo "┌─────────────────────────────────────────────────────────────"
    echo "│  TOP CPU-CONSUMING PROCESSES"
    echo "├─────────────────────────────────────────────────────────────"
    ps -eo comm,%cpu --sort=-%cpu 2>/dev/null | awk 'NR>1&&NR<=6{
        printf "│  %-3d  %-36s  %s%%\n", NR-1, $1, $2}'
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─────────────────────────────────────────────────────────────"
    echo "│  TOP MEMORY-CONSUMING PROCESSES"
    echo "├─────────────────────────────────────────────────────────────"
    ps -eo comm,%mem --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=6{
        printf "│  %-3d  %-36s  %s%%\n", NR-1, $1, $2}'
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─────────────────────────────────────────────────────────────"
    echo "│  TOP URLs BY HIT COUNT  (from access logs)"
    echo "├─────────────────────────────────────────────────────────────"
    local url_tmp=$(mktemp)
    for logfile in $ACCESSLOG_PATH; do
        [ -f "$logfile" ] || continue
        domain=$(echo "$logfile" | awk -F'/' '{print $5}')
        awk -v dom="$domain" '{print dom, $7}' "$logfile" 2>/dev/null
    done | sort | uniq -c | sort -nr | head -10 > "$url_tmp"
    awk '{printf "│  %-8s  %-28s  %s\n", $1, $2, $3}' "$url_tmp"
    rm -f "$url_tmp"
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─────────────────────────────────────────────────────────────"
    echo "│  TOP IPs HITTING THE SERVER  (from access logs)"
    echo "├─────────────────────────────────────────────────────────────"
    for log in $ACCESSLOG_PATH; do
        [ -f "$log" ] && awk '{print $1}' "$log"
    done 2>/dev/null | sort | uniq -c | sort -nr | head -10 | \
        awk '{printf "│  %-8s  %s\n", $1, $2}'
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─────────────────────────────────────────────────────────────"
    echo "│  TOP URLs THIS MINUTE  (live window)"
    echo "├─────────────────────────────────────────────────────────────"
    local CUR_MIN=$(date "+%d/%b/%Y:%H:%M")
    local live_tmp=$(mktemp)
    for log in $ACCESSLOG_PATH; do
        [ -f "$log" ] || continue
        dom=$(echo "$log" | awk -F'/' '{print $5}')
        tail -n 500 "$log" | grep "$CUR_MIN" | \
            awk -v d="$dom" '{print d, $1, $7}' >> "$live_tmp"
    done
    if [ -s "$live_tmp" ]; then
        sort "$live_tmp" | uniq -c | sort -nr | head -10 | \
            awk '{printf "│  %-6s hits  %-28s  %-18s  %s\n", $1, $2, $3, $4}'
    else
        echo "│  (no traffic in current minute)"
    fi
    rm -f "$live_tmp"
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─────────────────────────────────────────────────────────────"
    echo "│  TOP 3 IPs THIS MINUTE  (live window)"
    echo "├─────────────────────────────────────────────────────────────"
    local live_ip_tmp=$(mktemp)
    for log in $ACCESSLOG_PATH; do
        [ -f "$log" ] || continue
        dom=$(echo "$log" | awk -F'/' '{print $5}')
        tail -n 500 "$log" | grep "$CUR_MIN" | \
            awk -v d="$dom" '{print d, $1}' >> "$live_ip_tmp"
    done
    if [ -s "$live_ip_tmp" ]; then
        sort "$live_ip_tmp" | uniq -c | sort -nr | head -3 | \
            awk '{printf "│  %-6s hits  %-28s  %s\n", $1, $2, $3}'
    else
        echo "│  (no traffic in current minute)"
    fi
    rm -f "$live_ip_tmp"
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─────────────────────────────────────────────────────────────"
    echo "│  PHP SLOWLOG — TOP OFFENDING PLUGIN + MOST COMMON CALL STACK"
    echo "├─────────────────────────────────────────────────────────────"
    if [ -f "$SLOWLOG" ]; then
        TOP_PLUGIN=$(grep "wp-content/plugins/" "$SLOWLOG" | \
            sed -rn 's/.*\/plugins\/([^/ ]+).*/\1/p' | \
            sort | uniq -c | sort -nr | head -1 | awk '{print $2}')

        if [ -n "$TOP_PLUGIN" ]; then
            TOP_COUNT=$(grep -c "$TOP_PLUGIN" "$SLOWLOG" | tr -d '[:space:]')
            TOP_DOM=$(grep "wp-content/plugins/$TOP_PLUGIN" "$SLOWLOG" | \
                sed -rn 's/.*\/domains\/([^/]+)\/.*/\1/p' | \
                sort | uniq -c | sort -nr | head -1 | awk '{print $2}')

            echo "│"
            printf "│  Plugin      : %s\n"  "$TOP_PLUGIN"
            printf "│  Domain      : %s\n"  "${TOP_DOM:-unknown}"
            printf "│  Slow entries: %s\n"  "$TOP_COUNT"
            echo "│"
            echo "│  Most frequently occurring stack frames:"
            echo "│  ──────────────────────────────────────────────────────────────"

            awk -v plugin="$TOP_PLUGIN" '
            BEGIN { has_plugin = 0; nframes = 0 }
            /^# Time:/ {
                if (has_plugin) { for (i = 0; i < nframes; i++) print frames[i] }
                has_plugin = 0; nframes = 0; next
            }
            /^\[0x/ {
                line = $0
                sub(/^\[0x[0-9a-fA-F]+\] /, "", line)
                sub(/\/home\/nginx\/domains\/[^\/]*\/public\//, "", line)
                frames[nframes++] = line
                if (line ~ plugin) has_plugin = 1
                next
            }
            END { if (has_plugin) for (i = 0; i < nframes; i++) print frames[i] }
            ' "$SLOWLOG" | \
            sort | uniq -c | sort -rn | head -20 | \
            while IFS= read -r ranked_line; do
                count=$(echo "$ranked_line" | awk '{print $1}')
                frame=$(echo "$ranked_line" | cut -d' ' -f2-)
                printf "│  [%3dx]  %s\n" "$count" "$frame"
            done

            echo "│"
            echo "│  Note: [Nx] = times this frame appeared across all slow entries"
        else
            echo "│  (no plugin entries found in slowlog)"
        fi
    else
        echo "│  (slowlog not found at: $SLOWLOG)"
    fi
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─────────────────────────────────────────────────────────────"
    echo "│  WP-LOGIN.PHP ACTIVITY"
    echo "├─────────────────────────────────────────────────────────────"
    local wl_total=0
    for log in $ACCESSLOG_PATH; do
        [ -f "$log" ] && grep -c "wp-login.php" "$log" 2>/dev/null || echo 0
    done | awk '{s+=$1} END{print s+0}' | read wl_total
    wl_total=$(( ${wl_total:-0} + 0 ))
    if [ "$wl_total" -gt 0 ]; then
        echo "│  ⚠  Total wp-login.php hits in logs: $wl_total"
        echo "│"
        echo "│  Top offending IPs:"
        for log in $ACCESSLOG_PATH; do
            [ -f "$log" ] && grep "wp-login.php" "$log"
        done 2>/dev/null | \
            awk '{print $1}' | sort | uniq -c | sort -nr | head -5 | \
            awk '{printf "│    %-8s  %s\n", $1, $2}'
    else
        echo "│  ✔  No wp-login.php hits detected"
    fi
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "════════════════════════════════════════════════════════════════"
    echo "  End of report  •  $(date '+%H:%M:%S')"
    echo "════════════════════════════════════════════════════════════════"

    } | tee "$RPT"

    echo ""
    echo "  Report saved to: $RPT"
}

# ════════════════════════════════════════════════
#  HTML REPORT
# ════════════════════════════════════════════════
REPORT_WEBROOT="/usr/local/nginx/html"
REPORT_SUBDIR="reports"
REPORT_BASE_URL=""
REPORT_ENDPOINT=""
REPORT_TOKEN="changeme123"

html_e() { printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'; }

json_str() {
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g'   \
        -e 's/	/\\t/g'   \
        -e ':a;N;$!ba;s/\n/\\n/g'
}

generate_html_report() {
    local NOW_FULL=$(date "+%A, %d %b %Y  %H:%M:%S")
    local NOW_SLUG=$(date '+%Y-%m-%d_%H-%M-%S')
    local HOST_FULL=$(hostname -f 2>/dev/null || hostname -s 2>/dev/null || echo "server")
    local HOST_SHORT=$(hostname -s 2>/dev/null || echo "server")
    local LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local UPTIME_S=$(uptime -p 2>/dev/null | sed 's/up //')
    local CUR_MIN=$(date "+%d/%b/%Y:%H:%M")

    local PUB_DIR="$REPORT_WEBROOT"
    [ -n "$REPORT_SUBDIR" ] && PUB_DIR="${REPORT_WEBROOT}/${REPORT_SUBDIR}"

    local PUBLIC_BASE="${REPORT_BASE_URL:-https://${HOST_FULL}}"
    PUBLIC_BASE="${PUBLIC_BASE%/}"

    local REPORT_URL="${PUBLIC_BASE}/${REPORT_SUBDIR}/${NOW_SLUG}.html"
    [ -z "$REPORT_SUBDIR" ] && REPORT_URL="${PUBLIC_BASE}/${NOW_SLUG}.html"
    local LATEST_URL="${PUBLIC_BASE}/report.html"
    local INDEX_URL="${PUBLIC_BASE}/${REPORT_SUBDIR}/"
    [ -z "$REPORT_SUBDIR" ] && INDEX_URL="${PUBLIC_BASE}/"

    if [ ! -d "$REPORT_WEBROOT" ]; then
        PUB_DIR="/tmp/monitor_reports"
        echo "  ⚠  Web root not found ($REPORT_WEBROOT), writing to $PUB_DIR"
    fi

    mkdir -p "$PUB_DIR" 2>/dev/null

    local HTML_FILE="${PUB_DIR}/${NOW_SLUG}.html"
    local LATEST_LINK="${REPORT_WEBROOT}/report.html"

    # CPU
    local cpu_rows=""
    while read -r proc pct; do
        local bar_w=$(echo "$pct" | awk '{v=int($1*2); if(v>100)v=100; print v}')
        local col; col=$(awk -v p="$pct" 'BEGIN{if(p+0>=50)print "#c92a2a"; else if(p+0>=20)print "#e67700"; else print "#2f9e44"}')
        cpu_rows+="<tr><td class='mono'>$(html_e "$proc")</td><td><div class='bar-cell'><div class='bar-track'><div class='bar-fill' style='width:${bar_w}%;background:${col}'></div></div><span class='bar-val' style='color:${col}'>${pct}%</span></div></td></tr>"
    done < <(ps -eo comm,%cpu --sort=-%cpu 2>/dev/null | awk 'NR>1&&NR<=8{print $1,$2}')

    # Memory
    local mem_rows=""
    while read -r proc pct; do
        local bar_w=$(echo "$pct" | awk '{v=int($1*5); if(v>100)v=100; print v}')
        local col; col=$(awk -v p="$pct" 'BEGIN{if(p+0>=20)print "#c92a2a"; else if(p+0>=10)print "#e67700"; else print "#1c7ed6"}')
        mem_rows+="<tr><td class='mono'>$(html_e "$proc")</td><td><div class='bar-cell'><div class='bar-track'><div class='bar-fill' style='width:${bar_w}%;background:${col}'></div></div><span class='bar-val' style='color:${col}'>${pct}%</span></div></td></tr>"
    done < <(ps -eo comm,%mem --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=8{print $1,$2}')

    # Top URLs all-time
    local url_tmp=$(mktemp)
    for logfile in $ACCESSLOG_PATH; do
        [ -f "$logfile" ] || continue
        domain=$(echo "$logfile" | awk -F'/' '{print $5}')
        awk -v dom="$domain" '{print dom, $7}' "$logfile" 2>/dev/null
    done | sort | uniq -c | sort -nr | head -10 > "$url_tmp"
    local url_rows=""
    while read -r hits dom url; do
        url_rows+="<tr><td class='count'>$(html_e "$hits")</td><td class='dim'>$(html_e "$dom")</td><td class='url-cell'>$(html_e "$url")</td></tr>"
    done < "$url_tmp"
    rm -f "$url_tmp"

    # Top IPs all-time
    local ip_tmp=$(mktemp)
    for log in $ACCESSLOG_PATH; do
        [ -f "$log" ] && awk '{print $1}' "$log"
    done 2>/dev/null | sort | uniq -c | sort -nr | head -10 > "$ip_tmp"

    local max_ip_hits=1
    max_ip_hits=$(head -1 "$ip_tmp" | awk '{print $1+0}'); [ "${max_ip_hits:-0}" -eq 0 ] && max_ip_hits=1
    local ip_rows=""
    while read -r hits ip; do
        local bw=$(awk -v h="$hits" -v m="$max_ip_hits" 'BEGIN{printf "%d", h/m*100}')
        ip_rows+="<tr><td class='count'>$(html_e "$hits")</td><td class='ip-cell'>$(html_e "$ip")</td><td><div class='bar-track'><div class='bar-fill' style='width:${bw}%;background:#1c7ed6'></div></div></td></tr>"
    done < "$ip_tmp"
    rm -f "$ip_tmp"

    # Live URLs
    local live_tmp=$(mktemp)
    for log in $ACCESSLOG_PATH; do
        [ -f "$log" ] || continue
        dom=$(echo "$log" | awk -F'/' '{print $5}')
        tail -n 500 "$log" | grep "$CUR_MIN" | \
            awk -v d="$dom" '{print d, $1, $7}' >> "$live_tmp"
    done
    local live_url_rows=""
    if [ -s "$live_tmp" ]; then
        while read -r hits dom ip url; do
            live_url_rows+="<tr><td class='count'>$(html_e "$hits")</td><td class='dim'>$(html_e "$dom")</td><td class='ip-cell'>$(html_e "$ip")</td><td class='url-cell'>$(html_e "$url")</td></tr>"
        done < <(sort "$live_tmp" | uniq -c | sort -nr | head -10)
    else
        live_url_rows="<tr><td colspan='4' class='empty'>No traffic in current minute window</td></tr>"
    fi

    # Live top 3 IPs
    local live_ip_rows=""
    if [ -s "$live_tmp" ]; then
        local max_live=1
        max_live=$(awk '{print $2}' "$live_tmp" | sort | uniq -c | sort -nr | head -1 | awk '{print $1+0}')
        [ "${max_live:-0}" -eq 0 ] && max_live=1
        while read -r hits dom ip; do
            hits=$(( ${hits:-0} + 0 ))
            local bw=$(awk -v h="$hits" -v m="$max_live" 'BEGIN{printf "%d", h/m*100}')
            live_ip_rows+="<tr><td class='count'>$(html_e "$hits")</td><td class='dim'>$(html_e "$dom")</td><td class='ip-cell'>$(html_e "$ip")</td><td><div class='bar-track'><div class='bar-fill' style='width:${bw}%;background:#1c7ed6'></div></div></td></tr>"
        done < <(awk '{print $1, $2}' "$live_tmp" | sort | uniq -c | sort -nr | head -3)
    else
        live_ip_rows="<tr><td colspan='4' class='empty'>No traffic in current minute window</td></tr>"
    fi
    rm -f "$live_tmp"

    # WP Login
    local wl_total=0
    for log in $ACCESSLOG_PATH; do
        [ -f "$log" ] || continue
        local _wc
        _wc=$(grep -c "wp-login.php" "$log" 2>/dev/null | tr -d '[:space:]')
        wl_total=$(( wl_total + ${_wc:-0} ))
    done
    local wl_status_class="ok" wl_status_text="No wp-login.php hits detected" wl_dot_class="ok"
    [ "$wl_total" -gt 0 ] && { wl_status_class="alert"; wl_dot_class="alert"; wl_status_text="Login page hits detected"; }
    local wl_ip_rows=""
    if [ "$wl_total" -gt 0 ]; then
        while read -r hits ip; do
            wl_ip_rows+="<tr><td class='count count-hi'>$(html_e "$hits")</td><td class='ip-cell'>$(html_e "$ip")</td></tr>"
        done < <(for log in $ACCESSLOG_PATH; do [ -f "$log" ] && grep "wp-login.php" "$log"; done 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -nr | head -5)
    fi

    # PHP Slowlog
    local sl_plugin="" sl_domain="" sl_count="0" sl_frame_rows=""
    if [ -f "$SLOWLOG" ]; then
        sl_plugin=$(grep "wp-content/plugins/" "$SLOWLOG" | \
            sed -rn 's/.*\/plugins\/([^/ ]+).*/\1/p' | \
            sort | uniq -c | sort -nr | head -1 | awk '{print $2}')
        if [ -n "$sl_plugin" ]; then
            sl_count=$(grep -c "$sl_plugin" "$SLOWLOG" 2>/dev/null | tr -d '[:space:]')
            sl_count=$(( ${sl_count:-0} + 0 ))
            sl_domain=$(grep "wp-content/plugins/$sl_plugin" "$SLOWLOG" | \
                sed -rn 's/.*\/domains\/([^/]+)\/.*/\1/p' | \
                sort | uniq -c | sort -nr | head -1 | awk '{print $2}')

            local max_frame=1
            local frames_tmp=$(mktemp)
            awk -v plugin="$sl_plugin" '
            BEGIN { has_plugin = 0; nframes = 0 }
            /^# Time:/ {
                if (has_plugin) for (i=0;i<nframes;i++) print frames[i]
                has_plugin=0; nframes=0; next
            }
            /^\[0x/ {
                line=$0
                sub(/^\[0x[0-9a-fA-F]+\] /,"",line)
                sub(/\/home\/nginx\/domains\/[^\/]*\/public\//,"",line)
                gsub(/"/,"\\\"",line)
                frames[nframes++]=line
                if(line~plugin) has_plugin=1
                next
            }
            END { if(has_plugin) for(i=0;i<nframes;i++) print frames[i] }
            ' "$SLOWLOG" | sort | uniq -c | sort -rn | head -20 > "$frames_tmp"

            max_frame=$(head -1 "$frames_tmp" | awk '{print $1+0}'); [ "${max_frame:-0}" -eq 0 ] && max_frame=1

            while IFS= read -r ranked_line; do
                local cnt=$(echo "$ranked_line" | awk '{print $1}')
                local frame=$(echo "$ranked_line" | cut -d' ' -f2-)
                cnt=$(( ${cnt:-0} + 0 ))
                local bw=$(awk -v c="$cnt" -v m="$max_frame" 'BEGIN{printf "%d", c/m*100}')
                local fn_part path_part line_part
                fn_part=$(echo "$frame"  | grep -oP '^[^\s]+\(\)')
                path_part=$(echo "$frame" | grep -oP '(?<=\(\) ).+(?=:\d+$)')
                line_part=$(echo "$frame" | grep -oP ':\d+$' | tr -d ':')
                if [ -n "$fn_part" ]; then
                    sl_frame_rows+="<div class='frame-row'>"
                    sl_frame_rows+="<div class='frame-cnt'>${cnt}×</div>"
                    sl_frame_rows+="<div class='frame-bar'><div class='frame-bar-fill' style='width:${bw}%'></div></div>"
                    sl_frame_rows+="<div class='frame-text'><span class='fn'>$(html_e "$fn_part")</span> <span class='fpath'>$(html_e "$path_part")</span><span class='fline'>:${line_part}</span></div>"
                    sl_frame_rows+="</div>"
                else
                    sl_frame_rows+="<div class='frame-row'><div class='frame-cnt'>${cnt}×</div><div class='frame-bar'><div class='frame-bar-fill' style='width:${bw}%'></div></div><div class='frame-text'>$(html_e "$frame")</div></div>"
                fi
            done < "$frames_tmp"
            rm -f "$frames_tmp"
        fi
    fi

    # MySQL top queries
    local mysql_query_rows=""
    local mysql_avail=0

    local mysql_raw
    mysql_raw=$(mysql --batch --silent -e "
        SELECT
            IFNULL(SCHEMA_NAME, '—')                  AS db,
            DIGEST_TEXT,
            COUNT_STAR,
            ROUND(SUM_TIMER_WAIT/1000000000000, 3)   AS total_sec,
            ROUND(AVG_TIMER_WAIT/1000000000000, 4)   AS avg_sec,
            ROUND(MAX_TIMER_WAIT/1000000000000, 3)   AS max_sec,
            SUM_ROWS_EXAMINED,
            SUM_ROWS_SENT,
            LAST_SEEN
        FROM performance_schema.events_statements_summary_by_digest
        WHERE DIGEST_TEXT IS NOT NULL
          AND DIGEST_TEXT NOT LIKE '%performance_schema%'
          AND DIGEST_TEXT NOT LIKE '%SHOW%'
        ORDER BY SUM_TIMER_WAIT DESC
        LIMIT 15;" 2>/dev/null)

    if [ -n "$mysql_raw" ]; then
        mysql_avail=1
        local max_total_sec=1
        local _mts
        _mts=$(echo "$mysql_raw" | awk -F'\t' 'NR==1{v=$4+0; print (v>0)?v:1}')
        [[ "$_mts" =~ ^[0-9]+(\.[0-9]+)?$ ]] && max_total_sec="$_mts"

        while IFS=$'\t' read -r db digest count total_sec avg_sec max_sec rows_exam rows_sent last_seen; do
            [ -z "$digest" ] && continue


            local tbl
            tbl=$(echo "$digest" | awk '{
                txt = toupper($0)
                n = split("FROM UPDATE INTO JOIN", keys, " ")
                for (kw_i = 1; kw_i <= n; kw_i++) {
                    kw = keys[kw_i]
                    pos = index(txt, " " kw " ")
                    if (pos > 0) {
                        rest = substr($0, pos + length(kw) + 2)
                        n2 = split(rest, parts, " ")
                        t = parts[1]
                        gsub(/[`()\[\]]/, "", t)
                        gsub(/,.*/, "", t)
                        if (t != "(" && t != "SELECT" && length(t) > 0) {
                            print t; exit
                        }
                    }
                }
                print "—"
            }')

            if [ -z "$tbl" ] || [ "$tbl" = "—" ]; then
                tbl=$(echo "$digest" | grep -ioP '(?<=\bFROM\b\s)\`?[a-zA-Z0-9_]+\`?' | head -1 | tr -d '`')
                [ -z "$tbl" ] && tbl=$(echo "$digest" | grep -ioP '(?<=\bUPDATE\b\s)\`?[a-zA-Z0-9_]+\`?' | head -1 | tr -d '`')
                [ -z "$tbl" ] && tbl=$(echo "$digest" | grep -ioP '(?<=\bINTO\b\s)\`?[a-zA-Z0-9_]+\`?' | head -1 | tr -d '`')
                [ -z "$tbl" ] && tbl="—"
            fi

            local short_digest="$digest"
            [ "${#digest}" -gt 110 ] && short_digest="${digest:0:107}..."

            local avg_col
            avg_col=$(awk -v a="$avg_sec" 'BEGIN{
                if(a+0>=1)         print "#c92a2a"
                else if(a+0>=0.1)  print "#e67700"
                else if(a+0>=0.01) print "#495057"
                else               print "#2f9e44"
            }')

            local max_col
            max_col=$(awk -v m="$max_sec" 'BEGIN{
                if(m+0>=5)        print "#c92a2a"
                else if(m+0>=1)   print "#e67700"
                else              print "#2f9e44"
            }')

            mysql_query_rows+="<tr>"
            mysql_query_rows+="<td class='db-stack'>"
            mysql_query_rows+="<div class='db-name'>$(html_e "$db")</div>"
            mysql_query_rows+="<div class='db-table'>$(html_e "$tbl")</div>"
            mysql_query_rows+="</td>"
            mysql_query_rows+="<td class='query-cell'>$(html_e "$short_digest")</td>"
            mysql_query_rows+="<td class='t-right t-num'>${count}</td>"
            mysql_query_rows+="<td class='t-right t-num'>${total_sec}s</td>"
            mysql_query_rows+="<td class='t-right t-num' style='color:${avg_col}'>${avg_sec}s</td>"
            mysql_query_rows+="<td class='t-right t-num' style='color:${max_col}'>${max_sec}s</td>"
            mysql_query_rows+="<td class='t-right t-num'>${rows_exam}</td>"
            mysql_query_rows+="<td class='t-right t-num'>${rows_sent}</td>"
            mysql_query_rows+="<td class='dim' style='white-space:nowrap'>${last_seen}</td>"
            mysql_query_rows+="</tr>"
        done <<< "$mysql_raw"
    fi

    cat > "$HTML_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Server Report — ${HOST_FULL}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
:root {
  --bg:      #f8f9fa;
  --surface: #ffffff;
  --border:  #e2e6ea;
  --border2: #ced4da;
  --txt:     #212529;
  --txt2:    #495057;
  --muted:   #6c757d;
  --light:   #f1f3f5;
  --accent:  #1c7ed6;
  --green:   #2f9e44;
  --red:     #c92a2a;
  --orange:  #e67700;
  --mono:    'JetBrains Mono', 'Courier New', monospace;
  --sans:    'Inter', system-ui, sans-serif;
  --radius:  6px;
  --shadow:  0 1px 3px rgba(0,0,0,.08), 0 1px 2px rgba(0,0,0,.06);
}
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body {
  background: var(--bg);
  color: var(--txt);
  font-family: var(--sans);
  font-size: 13.5px;
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
code {
  font-family: var(--mono);
  font-size: 12px;
  background: var(--light);
  padding: 1px 5px;
  border-radius: 3px;
  border: 1px solid var(--border);
  color: var(--txt2);
}

/* ── Layout ─────────────────────────────────── */
.wrap { max-width: 1280px; margin: 0 auto; padding: 32px 24px 64px; }
.grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 16px; }
.grid1 { display: grid; grid-template-columns: 1fr; gap: 16px; margin-bottom: 16px; }
@media (max-width: 800px) { .grid2 { grid-template-columns: 1fr; } }

/* ── Report header ───────────────────────────── */
.report-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 24px;
  flex-wrap: wrap;
  padding-bottom: 24px;
  margin-bottom: 28px;
  border-bottom: 2px solid var(--border);
}
.rh-left .report-label {
  font-size: 11px;
  font-weight: 600;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: var(--muted);
  margin-bottom: 4px;
}
.rh-left .report-host {
  font-size: 26px;
  font-weight: 600;
  color: var(--txt);
  line-height: 1.2;
}
.rh-right {
  text-align: right;
  font-size: 12.5px;
  color: var(--txt2);
  line-height: 1.7;
}
.rh-right strong { color: var(--txt); font-weight: 500; }

/* ── Breadcrumb / nav ────────────────────────── */
.nav-bar {
  font-size: 12px;
  color: var(--muted);
  margin-bottom: 24px;
  padding: 8px 12px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
}
.nav-bar a { color: var(--accent); }

/* ── Panels ──────────────────────────────────── */
.panel {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  overflow: hidden;
}
.panel-header {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 11px 16px;
  border-bottom: 1px solid var(--border);
  background: var(--light);
}
.panel-title {
  font-size: 12px;
  font-weight: 600;
  color: var(--txt);
  letter-spacing: .01em;
  flex: 1;
}

/* ── Status badges ───────────────────────────── */
.badge {
  display: inline-block;
  font-size: 11px;
  font-weight: 500;
  padding: 2px 8px;
  border-radius: 4px;
  border: 1px solid transparent;
}
.badge-ok     { background: #ebfbee; color: #2f9e44; border-color: #b2f2bb; }
.badge-warn   { background: #fff9db; color: #e67700; border-color: #ffec99; }
.badge-alert  { background: #fff5f5; color: #c92a2a; border-color: #ffc9c9; }
.badge-info   { background: #e7f5ff; color: #1971c2; border-color: #a5d8ff; }

/* ── Tables ──────────────────────────────────── */
table { width: 100%; border-collapse: collapse; }
thead tr { border-bottom: 1px solid var(--border); }
th {
  padding: 8px 14px;
  font-size: 11px;
  font-weight: 600;
  color: var(--muted);
  text-align: left;
  text-transform: uppercase;
  letter-spacing: .06em;
  background: var(--light);
}
td {
  padding: 9px 14px;
  font-size: 13px;
  color: var(--txt2);
  border-bottom: 1px solid var(--border);
  vertical-align: middle;
}
tr:last-child td { border-bottom: none; }
tbody tr:hover td { background: #f8f9fa; }

/* ── Count pill ──────────────────────────────── */
.count {
  display: inline-block;
  font-family: var(--mono);
  font-size: 11.5px;
  font-weight: 500;
  min-width: 42px;
  text-align: right;
  color: var(--txt);
}
.count-hi  { color: var(--red); }
.count-med { color: var(--orange); }

/* ── Bar chart ───────────────────────────────── */
.bar-cell { display: flex; align-items: center; gap: 10px; }
.bar-track { flex: 1; height: 5px; background: var(--border); border-radius: 3px; overflow: hidden; min-width: 60px; }
.bar-fill  { height: 100%; border-radius: 3px; }
.bar-val   { font-size: 12px; font-family: var(--mono); min-width: 40px; text-align: right; color: var(--txt2); }

/* ── Monospace cells ─────────────────────────── */
.mono     { font-family: var(--mono); font-size: 12px; color: var(--txt); }
.url-cell { font-family: var(--mono); font-size: 11.5px; color: var(--accent); word-break: break-all; max-width: 320px; }
.ip-cell  { font-family: var(--mono); font-size: 12px; color: var(--txt); }
.dim      { color: var(--muted); font-size: 12px; }

/* ── Status indicator ────────────────────────── */
.status-row { display: flex; align-items: center; gap: 12px; padding: 14px 16px; }
.status-dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
.status-dot.ok    { background: var(--green); }
.status-dot.alert { background: var(--red); }
.status-label { font-size: 13.5px; font-weight: 500; color: var(--txt); }
.status-count { margin-left: auto; font-size: 22px; font-weight: 600; font-family: var(--mono); color: var(--red); }

/* ── Key–value meta table ────────────────────── */
.kv-table { padding: 12px 16px 4px; }
.kv-table table { border: none; }
.kv-table td { border: none; padding: 4px 16px 4px 0; font-size: 12.5px; color: var(--txt2); }
.kv-table td:first-child { color: var(--muted); width: 120px; font-size: 12px; }
.kv-table td strong { color: var(--txt); font-weight: 500; }

/* ── Section label ───────────────────────────── */
.section-label {
  font-size: 11px;
  font-weight: 600;
  letter-spacing: .07em;
  text-transform: uppercase;
  color: var(--muted);
  padding: 14px 16px 6px;
}

/* ── Call stack frames ───────────────────────── */
.frame-list { padding: 4px 0 8px; }
.frame-row {
  display: flex;
  align-items: center;
  gap: 0;
  padding: 5px 16px;
  border-bottom: 1px solid var(--border);
}
.frame-row:last-child { border-bottom: none; }
.frame-row:hover { background: var(--light); }
.frame-cnt  { flex-shrink: 0; width: 40px; font-size: 11.5px; font-family: var(--mono); font-weight: 500; color: var(--muted); text-align: right; margin-right: 12px; }
.frame-bar  { flex-shrink: 0; width: 64px; height: 3px; background: var(--border); border-radius: 2px; margin-right: 14px; overflow: hidden; }
.frame-bar-fill { height: 100%; background: var(--orange); border-radius: 2px; }
.frame-text { flex: 1; font-family: var(--mono); font-size: 11.5px; color: var(--txt2); word-break: break-all; }
.fn    { color: var(--accent); font-weight: 500; }
.fpath { color: var(--muted); }
.fline { color: var(--orange); }

/* ── Empty state ─────────────────────────────── */
.empty { padding: 20px 16px; font-size: 12.5px; color: var(--muted); text-align: center; }

/* ── MySQL query table ───────────────────────── */
.query-cell {
  font-family: var(--mono);
  font-size: 11.5px;
  color: var(--txt2);
  word-break: break-all;
  max-width: 480px;
  line-height: 1.5;
}
.db-stack { white-space: nowrap; vertical-align: top; }
.db-name  { font-size: 12px; font-weight: 500; color: var(--accent); }
.db-table { font-size: 11px; color: var(--muted); margin-top: 2px; font-family: var(--mono); }
.mysql-note {
  padding: 10px 16px;
  font-size: 12px;
  color: var(--muted);
  border-bottom: 1px solid var(--border);
  background: var(--light);
}
.t-right { text-align: right; }
.t-num   { font-family: var(--mono); font-size: 12px; }

/* ── Footer ──────────────────────────────────── */
.report-footer {
  margin-top: 48px;
  padding-top: 16px;
  border-top: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 8px;
  font-size: 12px;
  color: var(--muted);
}
</style>
</head>
<body>
<div class="wrap">

<div class="nav-bar">
  <a href="./">All reports</a> &rsaquo; ${NOW_SLUG}.html
  &nbsp;&nbsp;&middot;&nbsp;&nbsp;
  <a href="../report.html">Latest report</a>
</div>

<div class="report-header">
  <div class="rh-left">
    <div class="report-label">Server Performance Report</div>
    <div class="report-host">${HOST_FULL}</div>
  </div>
  <div class="rh-right">
    <div><strong>${NOW_FULL}</strong></div>
    <div>Uptime: <strong>${UPTIME_S}</strong></div>
    <div>Load average: <strong>${LOAD}</strong></div>
  </div>
</div>

<div class="grid2">
  <div class="panel">
    <div class="panel-header"><span class="panel-title">CPU Usage — Top Processes</span></div>
    <table>
      <thead><tr><th>Process</th><th>CPU %</th></tr></thead>
      <tbody>${cpu_rows}</tbody>
    </table>
  </div>
  <div class="panel">
    <div class="panel-header"><span class="panel-title">Memory Usage — Top Processes</span></div>
    <table>
      <thead><tr><th>Process</th><th>Memory %</th></tr></thead>
      <tbody>${mem_rows}</tbody>
    </table>
  </div>
</div>

<div class="grid2">
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">Top URLs by Hit Count</span>
      <span class="badge badge-info">All-time</span>
    </div>
    <table>
      <thead><tr><th>Hits</th><th>Domain</th><th>URL</th></tr></thead>
      <tbody>${url_rows}</tbody>
    </table>
  </div>
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">Top IP Addresses by Hit Count</span>
      <span class="badge badge-info">All-time</span>
    </div>
    <table>
      <thead><tr><th>Hits</th><th>IP Address</th><th>Share</th></tr></thead>
      <tbody>${ip_rows}</tbody>
    </table>
  </div>
</div>

<div class="grid2">
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">Top URLs — Current Minute</span>
      <span class="badge badge-ok">Live</span>
    </div>
    <table>
      <thead><tr><th>Hits</th><th>Domain</th><th>IP</th><th>URL</th></tr></thead>
      <tbody>${live_url_rows}</tbody>
    </table>
  </div>
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">Top IP Addresses — Current Minute</span>
      <span class="badge badge-ok">Live</span>
    </div>
    <table>
      <thead><tr><th>Hits</th><th>Domain</th><th>IP</th><th>Share</th></tr></thead>
      <tbody>${live_ip_rows}</tbody>
    </table>
  </div>
</div>

<div class="grid1">
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">WP-Login.php Activity</span>
      $([ "$wl_total" -gt 0 ] && echo "<span class='badge badge-alert'>${wl_total} hits detected</span>" || echo "<span class='badge badge-ok'>No activity</span>")
    </div>
    <div class="status-row">
      <div class="status-dot ${wl_dot_class}"></div>
      <div>
        <div class="status-label">${wl_status_text}</div>
        $([ "$wl_total" -gt 0 ] && echo "<div class='dim' style='margin-top:2px'>Total hits recorded in access logs</div>")
      </div>
      $([ "$wl_total" -gt 0 ] && echo "<div class='status-count'>${wl_total}</div>")
    </div>
    $([ -n "$wl_ip_rows" ] && echo "<div class='section-label'>Top offending IP addresses</div><table><thead><tr><th>Hits</th><th>IP Address</th></tr></thead><tbody>${wl_ip_rows}</tbody></table>")
  </div>
</div>

<div class="grid1">
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">PHP Slow Log — Top Offending Plugin</span>
      $([ -n "$sl_plugin" ] && echo "<span class='badge badge-warn'>${sl_count} slow entries</span>")
    </div>
    $(if [ -n "$sl_plugin" ]; then
        echo "<div class='kv-table'><table><tbody>"
        echo "<tr><td>Plugin</td><td><strong>$(html_e "$sl_plugin")</strong></td></tr>"
        echo "<tr><td>Domain</td><td>$(html_e "$sl_domain")</td></tr>"
        echo "<tr><td>Slow entries</td><td><strong>${sl_count}</strong></td></tr>"
        echo "</tbody></table></div>"
        if [ -n "$sl_frame_rows" ]; then
            echo "<div class='section-label'>Most frequent call stack frames</div>"
            echo "<div class='frame-list'>${sl_frame_rows}</div>"
        fi
    else
        echo "<div class='empty'>No slow log data — slow log not configured or no entries recorded.</div>"
    fi)
  </div>
</div>

<div class="grid1">
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">MySQL — Top Queries by Total Execution Time</span>
      $([ "$mysql_avail" -eq 1 ] && echo "<span class='badge badge-info'>performance_schema</span>" || echo "<span class='badge badge-alert'>Unavailable</span>")
    </div>
    $(if [ "$mysql_avail" -eq 1 ] && [ -n "$mysql_query_rows" ]; then
        echo "<div class='mysql-note'>Aggregated since last server restart or <code>TRUNCATE performance_schema.events_statements_summary_by_digest</code>. Sorted by total cumulative execution time.</div>"
        echo "<div style='overflow-x:auto'>"
        echo "<table>"
        echo "<thead><tr>"
        echo "<th>Database / Table</th>"
        echo "<th>Query Digest</th>"
        echo "<th class='t-right'>Calls</th>"
        echo "<th class='t-right'>Total time</th>"
        echo "<th class='t-right'>Avg time</th>"
        echo "<th class='t-right'>Max time</th>"
        echo "<th class='t-right'>Rows examined</th>"
        echo "<th class='t-right'>Rows sent</th>"
        echo "<th>Last seen</th>"
        echo "</tr></thead>"
        echo "<tbody>${mysql_query_rows}</tbody>"
        echo "</table></div>"
    else
        echo "<div class='empty'>$([ "$mysql_avail" -eq 0 ] && echo 'MySQL is not accessible or performance_schema is not enabled.' || echo 'No query data available.')</div>"
    fi)
  </div>
</div>

<div class="report-footer">
  <span>Server Monitor Dashboard &middot; ${HOST_FULL}</span>
  <span>Generated ${NOW_FULL}</span>
</div>

</div>
</body>
</html>
HTMLEOF

    echo "  ✔  HTML report written: $HTML_FILE"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────"
    echo "  │  📄 This report  : ${REPORT_URL}"
    echo "  │  🔗 Latest (always): ${LATEST_URL}"
    echo "  │  📁 All reports  : ${INDEX_URL}"
    echo "  └─────────────────────────────────────────────────────"
    echo ""

    local REL_PATH
    if [ -n "$REPORT_SUBDIR" ]; then
        REL_PATH="${REPORT_SUBDIR}/${NOW_SLUG}.html"
    else
        REL_PATH="${NOW_SLUG}.html"
    fi

    cat > "${REPORT_WEBROOT}/report.html" << REDIREOF
<!DOCTYPE html>
<html><head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="0;url=${REL_PATH}">
<title>Redirecting to latest report...</title>
</head><body>
<p>Redirecting to <a href="${REL_PATH}">latest report</a>...</p>
</body></html>
REDIREOF
    echo "  ✔  Latest redirect  : ${LATEST_URL}"

    {
        echo '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
        echo '<meta name="viewport" content="width=device-width,initial-scale=1">'
        echo "<title>Reports — ${HOST_FULL}</title>"
        echo '<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">'
        echo '<style>body{background:#f8f9fa;color:#212529;font-family:Inter,system-ui,sans-serif;padding:40px 24px;max-width:860px;margin:0 auto;font-size:14px;-webkit-font-smoothing:antialiased}h1{font-size:22px;font-weight:600;color:#212529;margin-bottom:6px}p{color:#6c757d;font-size:13px;margin-bottom:28px}a{color:#1c7ed6;text-decoration:none}a:hover{text-decoration:underline}.report-list{list-style:none;border:1px solid #e2e6ea;border-radius:6px;overflow:hidden;background:#fff}.report-list li{border-bottom:1px solid #e2e6ea;padding:11px 16px;display:flex;align-items:center;gap:12px;font-size:13px}.report-list li:last-child{border-bottom:none}.report-list a{color:#1c7ed6}.ts{color:#adb5bd;font-size:12px;margin-left:auto;font-family:monospace}.latest{background:#e7f5ff;border-left:3px solid #1c7ed6}</style>'
        echo '</head><body>'
        echo "<h1>${HOST_FULL}</h1>"
        echo "<p>Server performance reports &middot; <a href='../report.html'>Latest report</a></p>"
        echo '<ul class="report-list">'
        local first=1
        for f in $(ls -t "$PUB_DIR"/*.html 2>/dev/null); do
            local fname=$(basename "$f")
            local fdate=$(echo "$fname" | sed 's/_/ /;s/-/:/g;s/\.html//')
            if [ "$first" -eq 1 ]; then
                echo "<li class='latest'><a href='${fname}'>${fname}</a><span class='ts'>Latest</span></li>"
                first=0
            else
                echo "<li><a href='${fname}'>${fname}</a><span class='ts'>${fdate}</span></li>"
            fi
        done
        echo '</ul></body></html>'
    } > "${PUB_DIR}/index.html"
    echo "  ✔  Report index     : ${INDEX_URL}"

    local old_reports
    old_reports=$(ls -t "$PUB_DIR"/*.html 2>/dev/null | grep -v "index.html" | tail -n +31)
    if [ -n "$old_reports" ]; then
        echo "$old_reports" | xargs rm -f
        echo "  ✔  Pruned old reports (kept latest 30)"
    fi

    if [ -n "$REPORT_ENDPOINT" ]; then
        local JSON_FILE="/tmp/monitor_report_${NOW_SLUG}.json"
        cat > "$JSON_FILE" << JSONEOF
{"meta":{"generated":"$(json_str "$NOW_FULL")","host":"$(json_str "$HOST_FULL")","uptime":"$(json_str "$UPTIME_S")","load":"$(json_str "$LOAD")"}}
JSONEOF
        echo "  Sending to $REPORT_ENDPOINT ..."
        http_code=$(curl -s -o /tmp/report_resp.txt -w "%{http_code}" \
            -X POST -H "Content-Type: application/json" \
            -H "X-Report-Token: ${REPORT_TOKEN}" \
            --data-binary "@${JSON_FILE}" "$REPORT_ENDPOINT" 2>/dev/null)
        [ "$http_code" = "200" ] && echo "  ✔  Remote: $(cat /tmp/report_resp.txt)" || echo "  ✘  Remote send failed (HTTP $http_code)"
        rm -f "$JSON_FILE" /tmp/report_resp.txt
    fi
}

trap '
    echo ""
    echo "  Generating exit report..."
    echo ""
    generate_report
    echo ""
    echo "  Writing HTML report to web root..."
    echo ""
    generate_html_report
    rm -f "$FRAME"
    exit 0
' INT

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

    # ── DISK WARNING ──────────────────────────────
    DISK_WARN=""
    while read -r pct mount; do
        pct_num="${pct%%%}"   # strip the % sign
        if [ "${pct_num:-0}" -ge 98 ] 2>/dev/null; then
            DISK_WARN="${DISK_WARN}${mount} at ${pct}  "
        fi
    done < <(df -h --output=pcent,target 2>/dev/null | awk 'NR>1 && $1!="Use%"')

    # ── HEADER ────────────────────────────────────
    hline '═' "$BLUE_D"
    hdr_left="  🖥  SYSTEM MONITOR DASHBOARD"
    pad=$(( TW - ${#hdr_left} - ${#NOW} - 4 ))
    [ "$pad" -lt 1 ] && pad=1
    printf "${BG_HEADER}${CYAN}${BOLD}%s%*s${YELLOW}%s  ${R}\n" "$hdr_left" "$pad" "" "$NOW"
    hline '═' "$BLUE_D"

    if [ -n "$DISK_WARN" ]; then
        hline '█' "$BG_ALERT"
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

    # ── SYSTEM PRESSURE BAR ───────────────────────
    {
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
        IOWAIT_PCT=$(( ${IOWAIT_PCT:-0} + 0 ))

        MEM_AVAIL=$(awk '/^MemAvailable:/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null)
        MEM_TOTAL=$(awk '/^MemTotal:/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null)
        MEM_USED=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{
            if(t>0) printf "%.0f", ((t-a)/t)*100; else print "0"}' /proc/meminfo 2>/dev/null)
        MEM_USED=$(( ${MEM_USED:-0} + 0 ))

        SWAP_USED=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{
            used=(t-f)/1024; printf "%.0fM", used}' /proc/meminfo 2>/dev/null)
        SWAP_TOTAL=$(awk '/^SwapTotal:/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)

        SWAP_IN=0; SWAP_OUT=0
        if command -v vmstat &>/dev/null; then
            vmstat_line=$(vmstat 1 2 2>/dev/null | tail -1)
            SWAP_IN=$(echo  "$vmstat_line" | awk '{print $7+0}')
            SWAP_OUT=$(echo "$vmstat_line" | awk '{print $8+0}')
        fi
        SWAP_IN=$(( ${SWAP_IN:-0} + 0 ))
        SWAP_OUT=$(( ${SWAP_OUT:-0} + 0 ))

        DSTATE=$(ps -eo stat 2>/dev/null | grep -c '^D' | tr -d '[:space:]')
        DSTATE=$(( ${DSTATE:-0} + 0 ))

        OOM_COUNT=$(dmesg 2>/dev/null | tail -n 100 | grep -c "Out of memory\|oom-kill" | tr -d '[:space:]')
        OOM_COUNT=$(( ${OOM_COUNT:-0} + 0 ))

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

        if [ "$IOWAIT_PCT" -ge 50 ] || [ "$MEM_USED" -ge 95 ] || \
           [ "$DSTATE"     -ge 10 ] || [ "$OOM_COUNT" -ge 1 ]; then
            printf "  ${BG_ALERT}${RED}${BOLD}${BLINK} ⚠ HIGH LOAD DETECTED ${R}"
        fi
        printf "\n"

        printf "  ${DGRAY}CPU iowait:${R} ${iowait_col}${BOLD}%-6s%%${R}  " "${IOWAIT_PCT}"
        printf "${DGRAY}Mem used:${R} ${mem_col}${BOLD}%-4s%%${R} ${DGRAY}(${R}${WHITE}${MEM_AVAIL:-0}G avail / ${MEM_TOTAL:-0}G${R}${DGRAY})${R}  "
        printf "${DGRAY}Swap:${R} ${swap_col}${BOLD}%-6s${R}  "  "${SWAP_USED:-0M}"
        printf "${DGRAY}Swap I/O in/out:${R} ${swap_col}${BOLD}%s/%s KB/s${R}  " "$SWAP_IN" "$SWAP_OUT"
        printf "${DGRAY}D-state procs:${R} ${dstate_col}${BOLD}%s${R}  " "$DSTATE"
        printf "${DGRAY}OOM kills:${R} ${oom_col}${BOLD}%s${R}\n" "$OOM_COUNT"
    }
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 1: CPU (left) | Memory (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

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

    {
        printf "${CYAN}${BOLD}  ▶  TOP IPs & TRAFFIC SPIKES${R}\n"
        printf "  ${DGRAY}%-${COL_IP_HITS}s %-${COL_IP_ADDR}s %s${R}\n" "HITS" "IP ADDRESS" "Δ"
        printf "  ${DGRAY}%-${COL_IP_HITS}s %-${COL_IP_ADDR}s %s${R}\n" "────────" "────────────────────────────" "──────"
        new_state=$(mktemp)
        for log in $ACCESSLOG_PATH; do
            [ -f "$log" ] && awk '{print $1}' "$log"
        done 2>/dev/null | sort | uniq -c | sort -nr | head -8 | \
        while read -r count ip; do
            [ -z "$ip" ] && continue
            count=$(( ${count:-0} + 0 ))
            echo "$ip $count" >> "$new_state"
            prev=$(grep "^$ip " "$IP_STATE_FILE" 2>/dev/null | awk '{print $2+0}')
            prev=$(( ${prev:-0} + 0 ))
            if [ -n "$prev" ] && [ "$prev" -gt 0 ]; then
                diff=$(( count - prev ))
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
        syn_count=$(netstat -ant 2>/dev/null | grep -c "SYN_RECV" | tr -d '[:space:]')
        syn_count=$(( ${syn_count:-0} + 0 ))
        if [ "$syn_count" -gt 20 ]; then
            printf "\n  ${RED}${BOLD}${BLINK}⚠ SYN FLOOD: %s conns!${R}\n" "$syn_count"
        fi
    } > "$C1"

    {
        WL_NOW=$(date "+%H:%M:%S")
        WL_CUR_MIN=$(date "+%d/%b/%Y:%H:%M")
        WL_PREV_MIN=$(date -d "1 minute ago" "+%d/%b/%Y:%H:%M" 2>/dev/null || \
                      date -v-1M "+%d/%b/%Y:%H:%M" 2>/dev/null)

        wplogin_raw=""
        for log in $ACCESSLOG_PATH; do
            [ -f "$log" ] && wplogin_raw+=$(grep "wp-login.php" "$log" 2>/dev/null)$'\n'
        done

        wplogin_recent=$(echo "$wplogin_raw" | grep -c "${WL_CUR_MIN}\|${WL_PREV_MIN}" 2>/dev/null | tr -d '[:space:]')
        wplogin_recent=$(( ${wplogin_recent:-0} + 0 ))
        wplogin_total=$(echo "$wplogin_raw" | grep -c "wp-login" 2>/dev/null | tr -d '[:space:]')
        wplogin_total=$(( ${wplogin_total:-0} + 0 ))

        if [ "$wplogin_recent" -gt 0 ]; then
            status_dot="${RED}${BOLD}${BLINK}●${R}"
            status_label="${RED}${BOLD}${BLINK}  ⚠  WP-LOGIN.PHP — ACTIVE ATTACK${R}"
        elif [ "$wplogin_total" -gt 0 ]; then
            status_dot="${ORANGE}${BOLD}●${R}"
            status_label="${ORANGE}${BOLD}  ⚠  WP-LOGIN.PHP — PRIOR HITS${R}"
        else
            status_dot="${GREEN_S}${BOLD}${BLINK}●${R}"
            status_label="${GREEN_S}${BOLD}  ✔  WP-LOGIN.PHP — CLEAR${R}"
        fi

        label_vis="  WP-LOGIN.PHP MONITOR"
        time_str="as of ${WL_NOW}"
        pad=$(( HALF - ${#label_vis} - ${#time_str} - 4 ))
        [ "$pad" -lt 1 ] && pad=1
        printf "  %b ${DGRAY}WP-LOGIN.PHP MONITOR%*s${DIM}%s${R}\n" \
            "$status_dot" "$pad" "" "$time_str"

        printf "%b\n" "$status_label"

        if [ "$wplogin_total" -gt 0 ]; then
            printf "  ${DGRAY}Total hits in log:${R} ${ORANGE}${BOLD}%s${R}  " "$wplogin_total"
            printf "${DGRAY}Active (last 2m):${R} "
            if [ "$wplogin_recent" -gt 0 ]; then
                printf "${RED}${BOLD}${BLINK}%s${R}\n" "$wplogin_recent"
            else
                printf "${GREEN_S}0${R}\n"
            fi

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
                }' | sort -nr | head -6 | \
            while read -r hits domain ip method ts; do
                echo "$wplogin_raw" | grep -q "$ip.*${WL_CUR_MIN}\|$ip.*${WL_PREV_MIN}" \
                    && row_col="${RED}" || row_col="${ORANGE}"
                [ "$method" = "POST" ] && mfmt="${RED}${BOLD}[POST]${R}" || mfmt="${GREEN_S}[GET] ${R}"
                printf "  ${row_col}%-${COL_WL_HITS}s${R}  ${GREEN_S}%-${COL_WL_DOM}.${COL_WL_DOM}s${R}  ${CYAN_S}%-${COL_WL_IP}.${COL_WL_IP}s${R}  %b  ${GRAY}%s${R}\n" \
                    "$hits" "$domain" "$ip" "$mfmt" "$ts"
            done
        else
            printf "  ${GREEN_S}No wp-login.php hits in access logs.${R}\n"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"
    # ════════════════════════════════════════════
    #  BLOCK 7: FILE CHANGES (left) | PHP SLOWLOG (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    {
        CUR_TIME=$(date +%s)
        LAST_FILE_SCAN=$(cat "$FILE_SCAN_TS" 2>/dev/null | tr -d '[:space:]')
        LAST_FILE_SCAN=$(( ${LAST_FILE_SCAN:-0} + 0 ))

        if (( CUR_TIME - LAST_FILE_SCAN > SCAN_INTERVAL )); then
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
                key = $1 "\t" $2 "\t" $3
                count[key]++
                if ($4 > latest[key]) latest[key] = $4
            }
            END {
                for (k in count) {
                    split(k, p, "\t")
                    printf "%s\t%s\t%s\t%d\t%s\n", p[1], p[2], p[3], count[k], latest[k]
                }
            }' \
            | sort -t$'\t' -k5,5r \
            | head -12 > "$FILE_CACHE"

            echo "$CUR_TIME" > "$FILE_SCAN_TS"
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
                count=$(( ${count:-0} + 0 ))
                if [ "$count" -gt 5 ]; then
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
    #  BLOCK 5: LIVE URL HITS — FULL WIDTH
    # ════════════════════════════════════════════
    {
        LIVE_URL_STATE="/tmp/live_url_ip.state"
        NEW_LIVE_STATE=$(mktemp)
        CUR_MIN=$(date "+%d/%b/%Y:%H:%M")

        COL_LV_HITS=6
        COL_LV_DELTA=10
        COL_LV_IP=18
        COL_LV_DOM=20
        COL_LV_METHOD=6
        COL_LV_STATUS=6
        COL_LV_URL=$(( TW - COL_LV_HITS - COL_LV_DELTA - COL_LV_IP - COL_LV_DOM - COL_LV_METHOD - COL_LV_STATUS - 16 ))
        [ "$COL_LV_URL" -lt 24 ] && COL_LV_URL=24

        printf "${CYAN}${BOLD}  ▶  LIVE TRAFFIC  ${DGRAY}(current minute window: %s)${R}\n" "$CUR_MIN"

        for log in $ACCESSLOG_PATH; do
            [ -f "$log" ] || continue
            dom=$(echo "$log" | awk -F'/' '{print $5}')
            tail -n 500 "$log" | grep "$CUR_MIN" | \
                awk -v d="$dom" '{
                    ip=$1
                    meth=$6; gsub(/\042/,"",meth)
                    url=$7
                    status=$9
                    print d, ip, meth, url, status
                }' >> "$NEW_LIVE_STATE"
        done

        if [ -s "$NEW_LIVE_STATE" ]; then

            LIVE_VEL_STATE="/tmp/live_vel_domip.state"

            COL_VS_HITS=6
            COL_VS_DOM=24
            COL_VS_IP=18
            COL_VS_DELTA=12

            printf "\n  ${CYAN}${DIM}▸  TOP IPs THIS MINUTE${R}  ${DGRAY}domain · ip · hits · Δ since last refresh${R}\n"
            printf "  ${DGRAY}%-${COL_VS_HITS}s  %-${COL_VS_DOM}s  %-${COL_VS_IP}s  %s${R}\n" \
                "HITS" "DOMAIN" "IP" "Δ CHANGE"
            printf "  ${DGRAY}%-${COL_VS_HITS}s  %-${COL_VS_DOM}s  %-${COL_VS_IP}s  %s${R}\n" \
                "──────" "$(printf '─%.0s' $(seq 1 $COL_VS_DOM))" \
                "$(printf '─%.0s' $(seq 1 $COL_VS_IP))" "────────────"

            awk '{print $1, $2}' "$NEW_LIVE_STATE" | \
            sort | uniq -c | sort -nr | head -10 | \
            while read -r count dom ip; do
                [ -z "$ip" ] && continue
                count=$(( ${count:-0} + 0 ))

                state_key="${dom}|${ip}"
                prev=$(grep "^${state_key}=" "$LIVE_VEL_STATE" 2>/dev/null | cut -d'=' -f2)
                prev=$(( ${prev:-0} + 0 ))

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
                hits=$(( ${hits:-0} + 0 ))

                state_key="${dom}|${ip}|${url}"
                prev=$(grep "^${state_key}=" "$LIVE_URL_STATE" 2>/dev/null | cut -d'=' -f2)
                prev=$(( ${prev:-0} + 0 ))

                if [ "$prev" -eq 0 ]; then
                    delta="${ORANGE}${BOLD}NEW${R}"
                else
                    diff=$(( hits - prev ))
                    if   [ "$diff" -gt 0 ]; then delta="${RED}${BOLD}↑ +${diff}${R}"
                    elif [ "$diff" -lt 0 ]; then delta="${GREEN_S}↓ ${diff}${R}"
                    else                          delta="${DGRAY}  —${R}"
                    fi
                fi

                echo "${state_key}=${hits}" >> "${LIVE_URL_STATE}.new"

                case "$meth" in
                    POST|PUT|DELETE) mc="${RED_S}" ;;
                    GET)             mc="${CYAN_S}" ;;
                    *)               mc="${GRAY}" ;;
                esac

                case "${status:0:1}" in
                    5) sc="${RED}${BOLD}" ;;
                    4) sc="${ORANGE}" ;;
                    3) sc="${YELLOW}" ;;
                    *)  sc="${GREEN_S}" ;;
                esac

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

            mv "${LIVE_URL_STATE}.new" "$LIVE_URL_STATE" 2>/dev/null

        else
            printf "  ${GRAY}${DIM}(no traffic in current minute window — waiting...)${R}\n"
        fi

        rm -f "$NEW_LIVE_STATE"
    }
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 6: MYSQL ACTIVE PROCESSES — FULL WIDTH
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
            while IFS=$'\t' read -r id db time state query; do
                [[ "$id" == "ID" ]] && continue
                [ -z "$id" ]        && continue

                time=$(( ${time:-0} + 0 ))
                if [ "$time" -ge 5 ]; then
                    tc="\033[38;5;196m"
                else
                    tc="\033[38;5;214m"
                fi

                printf "  \033[38;5;244m%-${COL_MYSQL_ID}s\033[0m" "$id"
                printf " \033[38;5;82m%-${COL_MYSQL_DB}.${COL_MYSQL_DB}s\033[0m" "$db"
                printf " ${tc}%-${COL_MYSQL_TIME}s\033[0m" "${time}s"
                printf " \033[38;5;45m%-${COL_MYSQL_STATE}.${COL_MYSQL_STATE}s\033[0m\n" "$state"

                clean_query=$(echo "$query" | tr '\n\t' '  ' | tr -s ' ')
                echo "$clean_query" | fold -s -w "$COL_MYSQL_QUERY" | \
                while IFS= read -r qline; do
                    printf "  \033[38;5;240m│\033[0m \033[38;5;255m%s\033[0m\n" "$qline"
                done

                printf "  \033[38;5;237m%s\033[0m\n" \
                    "$(printf '╌%.0s' $(seq 1 $(( TW - 4 ))))"
            done <<< "$mysql_out"
        fi
    }
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 9: NGINX ERROR LOG MONITOR — FULL WIDTH
    # ════════════════════════════════════════════
    {
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
            domain=$(echo "$errlog" | cut -d'/' -f5)

            tail -n 200 "$errlog" 2>/dev/null | awk '
            /\[error\]/ {
                ts = $1 " " $2
                snippet = ""
                for (i=5; i<=NF; i++) snippet = snippet " " $i
                sub(/^ \*[0-9]+ /, "", snippet)

                client = ""
                if (match(snippet, /client: ([0-9.]+|[0-9a-f:]+)/, arr)) {
                    client = arr[1]
                } else {
                    n = split(snippet, parts, ", ")
                    for (j=1; j<=n; j++) {
                        if (parts[j] ~ /^client:/) { client = parts[j]; sub(/^client: /,"",client); break }
                    }
                }

                req = ""
                if (match(snippet, /request: "([^"]+)"/, arr2)) {
                    req = arr2[1]
                    sub(/ HTTP\/[0-9.]+$/, "", req)
                } else {
                    n2 = split(snippet, parts2, ", ")
                    for (j2=1; j2<=n2; j2++) {
                        if (parts2[j2] ~ /^request:/) { req = parts2[j2]; sub(/^request: "/,"",req); sub(/"$/,"",req); break }
                    }
                }

                core = snippet
                sub(/, client:.*$/, "", core)
                gsub(/^[ \t]+|[ \t]+$/, "", core)

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
                cnt=$(( ${cnt:-0} + 0 ))

                state_key="${domain}|${client}|${req}"
                echo "${state_key}=${cnt}" >> "$NEW_ERR_STATE"

                prev_cnt=$(grep "^${state_key}=" "$ERRLOG_STATE" 2>/dev/null | cut -d'=' -f2)
                prev_cnt=$(( ${prev_cnt:-0} + 0 ))

                if [ "$prev_cnt" -gt 0 ] && [ "$cnt" -ne "$prev_cnt" ]; then
                    diff=$(( cnt - prev_cnt ))
                    if [ "$diff" -gt 0 ]; then
                        delta="${RED}${BOLD}+${diff}${R}"
                    else
                        delta="${GREEN_S}${diff}${R}"
                    fi
                elif [ "$prev_cnt" -eq 0 ]; then
                    delta="${ORANGE}${BOLD}NEW${R}"
                else
                    delta="${DGRAY}—${R}"
                fi

                msg_short="${msg:0:$COL_ERR_SNIPPET}"

                printf "  \033[38;5;114m%-${COL_ERR_DOM}.${COL_ERR_DOM}s\033[0m" "$domain"
                printf " \033[38;5;244m%-${COL_ERR_TIME}.${COL_ERR_TIME}s\033[0m" "$ts"
                printf " %-${COL_ERR_DELTA}b" "$delta"
                printf " \033[38;5;203m%-${COL_ERR_CLIENT}.${COL_ERR_CLIENT}s\033[0m" "$client"
                printf " \033[38;5;45m%-${COL_ERR_REQ}.${COL_ERR_REQ}s\033[0m" "$req"
                printf " \033[38;5;255m%s\033[0m\n" "$msg_short"
            done
        done

        [ -s "$NEW_ERR_STATE" ] && mv "$NEW_ERR_STATE" "$ERRLOG_STATE" || rm -f "$NEW_ERR_STATE"

        if [ "$found_any" -eq 0 ]; then
            printf "  ${GREEN_S}${DIM}(no errors found in nginx logs)${R}\n"
        fi
    }
    hline '─' "$DGRAY"

     # ════════════════════════════════════════════
    #  BLOCK 4: PHP-FPM Pools (left) | MySQL Health (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    {
        printf "${CYAN}${BOLD}  ▶  PHP-FPM POOLS${R}\n"
        printf "  ${DGRAY}%-${COL_FPM_POOL}s %-${COL_FPM_ACT}s %-${COL_FPM_IDLE}s %-${COL_FPM_MAX}s %-${COL_FPM_QUEUE}s %s${R}\n" \
            "POOL" "ACTIVE" "IDLE" "MAX" "QUEUE" "STATUS"
        printf "  ${DGRAY}%-${COL_FPM_POOL}s %-${COL_FPM_ACT}s %-${COL_FPM_IDLE}s %-${COL_FPM_MAX}s %-${COL_FPM_QUEUE}s %s${R}\n" \
            "$(printf '─%.0s' $(seq 1 $COL_FPM_POOL))" "──────" "─────" "─────" "──────" "──────────"

        fpm_found=0

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
                maxq=$(echo  "$status_raw" | grep "^max listen queue:"  | awk '{print $NF}')

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
                printf "${ORANGE}%-${COL_FPM_ACT}s${R} "    "$active"
                printf "${GRAY}%-${COL_FPM_IDLE}s${R} "     "$idle"
                printf "${DGRAY}%-${COL_FPM_MAX}s${R} "     "${maxc:-?}"
                printf "${YELLOW}%-${COL_FPM_QUEUE}s${R} "  "$queue"
                printf "%b\n" "$st"
            done
        fi

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

    {
        printf "${MAGENTA}${BOLD}  ▶  MYSQL HEALTH${R}\n"
        printf "  ${DGRAY}%-${COL_MH_LABEL}s %s${R}\n" "METRIC" "VALUE"
        printf "  ${DGRAY}%-${COL_MH_LABEL}s %s${R}\n" "$(printf '─%.0s' $(seq 1 $COL_MH_LABEL))" "──────────────"

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
            questions=$(( ${questions:-0} + 0 ))   # fix: coerce to int — prevents arithmetic syntax error on empty value
            max_conn=$(( ${max_conn:-0} + 0 ))       # fix: strip whitespace/newlines before division
            threads_conn=$(( ${threads_conn:-0} + 0 ))
            QPS=0
            if [ -n "$questions" ] && [ "${prev_q:-0}" -gt 0 ] && [ "$questions" -ge "${prev_q:-0}" ] 2>/dev/null; then
                QPS=$(( (questions - prev_q) / 20 ))   # 20s refresh interval
                [ "$QPS" -lt 0 ] && QPS=0
            fi
            echo "${questions:-0}" > "$MYSQL_QPS_STATE"

            # ── InnoDB buffer pool hit rate ────────────────────────────
            BP_HIT="n/a"
                if [ "$bp_req" -gt 0 ]; then
                BP_HIT=$(awk -v r="$bp_reads" -v req="$bp_req" \
                    'BEGIN{printf "%.1f%%", (1-(r/req))*100}')
            fi

            # ── Colour thresholds ──────────────────────────────────────
            conn_pct=0
            [ "$max_conn" -gt 0 ] && conn_pct=$(( threads_conn * 100 / max_conn ))

            conn_col="${GREEN_S}";   [ "$conn_pct"    -ge 70 ] && conn_col="${ORANGE}";  [ "$conn_pct"    -ge 90 ] && conn_col="${RED}${BOLD}"
            run_col="${GREEN_S}";    [ "$threads_run"  -ge 10 ] && run_col="${ORANGE}";   [ "$threads_run"  -ge 30 ] && run_col="${RED}${BOLD}"
            slow_col="${GREEN_S}";   [ "$slow_q"       -ge 5  ] && slow_col="${ORANGE}";  [ "$slow_q"       -ge 20 ] && slow_col="${RED}${BOLD}"
            lock_col="${GREEN_S}";   [ "$lock_wait"    -ge 1  ] && lock_col="${ORANGE}";  [ "$lock_wait"    -ge 10 ] && lock_col="${RED}${BOLD}"
            qps_col="${GREEN_S}";    [ "$QPS"          -ge 500 ] && qps_col="${ORANGE}";  [ "$QPS"          -ge 2000 ] && qps_col="${RED}${BOLD}"

            bp_col="${GREEN_S}"
            if [ "$BP_HIT" != "n/a" ]; then
                bp_col=$(awk -v h="$BP_HIT" 'BEGIN{
                    v = h + 0
                    if (v < 95)      print "\033[38;5;196m\033[1m"
                    else if (v < 99) print "\033[38;5;214m"
                    else             print "\033[38;5;114m"
                }')
            fi

            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${conn_col}%s / %s${R} ${DGRAY}(%s%%)${R}\n" \
                "Connections" "$threads_conn" "$max_conn" "$conn_pct"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${run_col}%s${R}\n" \
                "Threads running"  "$threads_run"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${qps_col}%s q/s${R}\n" \
                "QPS (last 20s)"   "$QPS"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${slow_col}%s${R}\n" \
                "Slow queries"     "$slow_q"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${lock_col}%s${R}\n" \
                "Table lock waits" "$lock_wait"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${bp_col}%s${R}\n" \
                "InnoDB hit rate"  "$BP_HIT"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${ORANGE}%s${R}\n" \
                "Row lock waits"   "$row_locks"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${GRAY}%s${R}\n" \
                "Aborted connects" "$aborted"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"



    # ════════════════════════════════════════════
    #  BLOCK 8: DISK I/O — FULL WIDTH
    # ════════════════════════════════════════════
    {
        printf "${YELLOW}${BOLD}  ▶  DISK I/O${R}\n"
        printf "  ${DGRAY}%-${COL_IO_DEV}s %-${COL_IO_READ}s %-${COL_IO_WRITE}s %-${COL_IO_AWAIT}s %-${COL_IO_UTIL}s %s${R}\n" \
            "DEVICE" "READ/s" "WRITE/s" "AWAIT(ms)" "UTIL%" "STATUS"
        printf "  ${DGRAY}%-${COL_IO_DEV}s %-${COL_IO_READ}s %-${COL_IO_WRITE}s %-${COL_IO_AWAIT}s %-${COL_IO_UTIL}s %s${R}\n" \
            "──────────" "──────────" "──────────" "────────────" "────────" "──────────"

        if command -v iostat &>/dev/null; then
            iostat -xk 1 2 2>/dev/null | awk '
            /^(sd|nvme|vd|xvd|hd)[a-z0-9]/ {
                dev=$1; rkbs=$6; wkbs=$7; await=$10; util=$NF
                uc="\033[38;5;82m"
                if (util+0 >= 50) uc="\033[38;5;214m"
                if (util+0 >= 85) uc="\033[38;5;196m\033[1m"
                ac="\033[38;5;82m"
                if (await+0 >= 20)  ac="\033[38;5;214m"
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
            }' | tail -n +2
        else
            snap1=$(awk '/^[ ]*[0-9]+ [0-9]+ (sd|nvme|vd)/ {print $3,$6,$10,$13}' /proc/diskstats 2>/dev/null)
            sleep 1
            snap2=$(awk '/^[ ]*[0-9]+ [0-9]+ (sd|nvme|vd)/ {print $3,$6,$10,$13}' /proc/diskstats 2>/dev/null)

            paste <(echo "$snap1") <(echo "$snap2") | awk '{
                dev=$1
                dr=($6-$2)*512/1024
                dw=($7-$3)*512/1024
                dio_ms=($8-$4)
                util=(dio_ms > 1000) ? 100 : (dio_ms > 0 ? dio_ms/10 : 0)

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



    # ── FOOTER ────────────────────────────────────
    printf "\n"
    hline '═' "$BLUE_D"
    printf "  ${GRAY}${DIM}Refreshing in ${R}${BOLD}${CYAN}20s${R}  ${DGRAY}•${R}  ${GRAY}${DIM}Ctrl+C to exit + generate report${R}\n"
    hline '═' "$BLUE_D"
    printf "\n"

    } > "$FRAME"

    clear
    cat "$FRAME"

    sleep 20
done
rm -f "$FRAME"