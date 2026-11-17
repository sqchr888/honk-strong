#!/bin/sh
# dns-engine.sh -- render mosdns-style DNS settings/rule lists into honk's
# config.dae managed blocks, then SIGHUP-reload honk.
#
# Safety contract (unchanged from the proven design):
#   * ONLY blocks between BEGIN/END markers are rewritten. The user's own
#     20+ routing rules, global{} / routing{} sections, and the honk-ads
#     reject rule are never touched.
#   * Both config.dae and config-draft.dae are updated.
#   * A backup is taken before any write; `rollback` restores it.
#   * `honk-core config validate` gates the write.
#   * No API password: SIGHUP is a root-only local reload primitive.
#
# Design: mosdns concepts -> honk dae syntax
#   DNS servers      -> named upstreams mos_local / mos_remote / mos_stream
#   whitelist        -> qname(...) -> mos_local
#   blacklist        -> qname(...) -> reject
#   greylist         -> qname(...) -> mos_remote
#   stream_media     -> qname(...) -> mos_stream
#   ddns             -> qname(...) -> mos_local  (TTL is global in honk)
#   hosts            -> qname(full:...) -> mos_local (honk has no A rewrite)
#   redirect         -> qname(full:...) -> mos_local (documented limitation)
#   ptr_blacklist    -> qname(full:...) -> reject
#   Each input line supports prefixes: domain:(suffix) full: keyword: geosite:
#   (bare domain is treated as suffix). '#' starts a comment.

. /lib/functions.sh

UCI_CONFIG=honk-dns
STAGE_ROOT=/tmp/honk-dns
CFG=/etc/honk/config.dae
DRAFT=/etc/honk/config-draft.dae
BACKUP_DIR=/etc/honk/dns-backup
CORE=/usr/bin/honk-core

UP_BEGIN='# HONK-DNS-UPSTREAM-BEGIN'
UP_END='# HONK-DNS-UPSTREAM-END'
RL_BEGIN='# HONK-DNS-MANAGED-BEGIN'
RL_END='# HONK-DNS-MANAGED-END'

log() { logger -t honk-dns "$*" 2>/dev/null || :; }
opt() { uci -q get "$UCI_CONFIG.main.$1" 2>/dev/null; }
def() {
	case "$1" in
		enabled) echo 1 ;; redirect) echo 1 ;; cache) echo 1 ;; reject_type65) echo 1 ;;
		local_dns) echo 'https://223.5.5.5/dns-query' ;;
		remote_dns) echo 'https://8.8.8.8/dns-query' ;;
		stream_dns) echo '' ;;
		bootstrap) echo '119.29.29.29:53' ;; fallback) echo remote ;;
		*) echo '' ;;
	esac
}
get() { local v; v=$(opt "$1"); [ -n "$v" ] && printf '%s' "$v" || def "$1"; }
onoff() { case "$1" in 1|true|on|yes) echo 1 ;; *) echo 0 ;; esac; }

# ---- helpers --------------------------------------------------------------
clean_line() { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# Convert one mosdns-style domain expression into a honk qname(...) matcher.
# echoes e.g. "suffix: example.com" or "geosite: cn"; empty if line is a comment.
to_matcher() {
	local e="$1"
	case "$e" in ''|\#*) return 0 ;; esac
	# strip trailing inline comment
	e=$(printf '%s' "$e" | sed 's/#.*$//' | sed 's/[[:space:]]*$//')
	[ -n "$e" ] || return 0
	case "$e" in
		geosite:*)  echo "geosite: $(printf '%s' "${e#geosite:}" | sed 's/^[[:space:]]*//')" ;;
		full:*)     echo "full: $(printf '%s' "${e#full:}" | sed 's/^[[:space:]]*//')" ;;
		keyword:*)  echo "keyword: $(printf '%s' "${e#keyword:}" | sed 's/^[[:space:]]*//')" ;;
		suffix:*)   echo "suffix: $(printf '%s' "${e#suffix:}" | sed 's/^[[:space:]]*//')" ;;
		domain:*)   echo "suffix: $(printf '%s' "${e#domain:}" | sed 's/^[[:space:]]*//')" ;;
		.*)         echo "suffix: ${e#.}" ;;
		*)          echo "suffix: $e" ;;
	esac
}

# render one list option: emit "            qname(<matcher>) -> <action>"
render_list() {
	local key=$1 action=$2 default_action=$3
	local content m line
	content=$(opt "$key")
	[ -n "$action" ] || action=$default_action
	[ -n "$content" ] || return 0
	printf '%s\n' "$content" | while IFS= read -r line; do
		line=$(clean_line "$line")
		m=$(to_matcher "$line")
		[ -n "$m" ] || continue
		printf '            qname(%s) -> %s\n' "$m" "$action"
	done
}

render_upstreams() {
	local local_dns remote_dns stream_dns
	local_dns=$(get local_dns); remote_dns=$(get remote_dns); stream_dns=$(opt stream_dns)
	printf '        %s\n' "$UP_BEGIN"
	# DNS 上游出站必须显式声明（参考 honk 文档 reference_dns）：
	#   国内上游 -> direct（直连可用），远程上游 -> Proxy（必须走代理，否则
	#   国内直连 8.8.8.8:443 不通 -> 所有境外域名解析超时、未命中 geosite:cn
	#   的国内查询卡在 fallback 上 -> 境外打不开 + 国内巨慢）。
	printf "            mos_local: '%s' -> direct\n" "$local_dns"
	printf "            mos_remote: '%s' -> Proxy\n" "$remote_dns"
	if [ -n "$stream_dns" ]; then
		printf "            mos_stream: '%s' -> Proxy\n" "$stream_dns"
	fi
	printf '        %s\n' "$UP_END"
}

render_rules() {
	local enabled ipv6 r65
	enabled=$(onoff "$(get enabled)")
	ipv6=$(onoff "$(opt ipv6)")
	r65=$(onoff "$(get reject_type65)")

	printf '            %s\n' "$RL_BEGIN"
	# master switch: when disabled, emit no rules at all (block stays empty)
	[ "$enabled" = 1 ] || { printf '            %s\n' "$RL_END"; return 0; }
	# reject HTTPS/SVCB (type 65) like mosdns reject_type65
	[ "$r65" = 1 ] && printf '            qtype(https, svcb) -> reject\n'
	# no IPv6 (AAAA) when disabled
	[ "$ipv6" = 0 ] && printf '            qtype(aaaa) -> reject\n'
	# PTR blacklist first
	render_list ptr_blacklist reject reject
	# blacklist -> reject
	render_list blacklist reject reject
	# whitelist -> local (highest priority among the lists)
	render_list whitelist mos_local mos_local
	# greylist -> remote
	render_list greylist mos_remote mos_remote
	# stream media -> stream (fallback to remote if none)
	if [ -n "$(opt stream_dns)" ]; then
		render_list stream_media mos_stream mos_stream
	else
		render_list stream_media mos_remote mos_remote
	fi
	# ddns / hosts / redirect -> local (honk limitation: no per-domain TTL/A-rewrite)
	render_list ddns mos_local mos_local
	render_list hosts mos_local mos_local
	render_list redirect_list mos_local mos_local
	# NOTE: no fallback here on purpose. In dae, `fallback` terminates the
	# routing section, so emitting it inside the managed block would shadow
	# all following user rules (incl. the honk-ads reject rule). The original
	# config.dae already has its own fallback at the end of request{}; keep it.
	printf '            %s\n' "$RL_END"
}

# ---- rewrite config: replace ONLY managed blocks -------------------------
rewrite_config() {
	local src=$1 out=$2 ups rules tmp
	mkdir -p "$STAGE_ROOT"
	ups="$STAGE_ROOT/ups.$$"; rules="$STAGE_ROOT/rules.$$"
	render_upstreams > "$ups" || { rm -f "$ups" "$rules"; return 1; }
	render_rules > "$rules" || { rm -f "$ups" "$rules"; return 1; }

	awk -v ub="$UP_BEGIN" -v ue="$UP_END" -v rb="$RL_BEGIN" -v re="$RL_END" \
	    -v upsf="$ups" -v rulesf="$rules" '
		function emit_file(f,   line, ind) {
			while ((getline line < f) > 0) print line
			close(f)
		}
		BEGIN { skip=0; u_done=0; r_done=0 }
		{
			line=$0
			if (index(line, ub)>0 || index(line, rb)>0) { skip=1; next }
			if (index(line, ue)>0 || index(line, re)>0) { skip=0; next }
			if (skip) next
			# Replace/insert upstream managed block right after "upstream {"
			if (!u_done && line ~ /^[[:space:]]*upstream[[:space:]]*\{/) {
				print line
				while ((getline ul < upsf) > 0) print ul
				close(upsf)
				u_done=1; next
			}
			# Replace/insert rules managed block right after "request {"
			if (!r_done && line ~ /^[[:space:]]*request[[:space:]]*\{/) {
				print line
				while ((getline rl < rulesf) > 0) print rl
				close(rulesf)
				r_done=1; next
			}
			print line
		}
		END { if (!u_done || !r_done) exit 1 }
	' "$src" > "$out"
	local rc=$?
	rm -f "$ups" "$rules"
	return $rc
}

validate() { [ -x "$CORE" ] || return 1; "$CORE" config validate --config "$1" >/dev/null 2>&1; }

backup() {
	mkdir -p "$BACKUP_DIR"
	local ts; ts=$(date +%Y%m%d-%H%M%S)
	[ -f "$CFG" ]   && cp -p "$CFG" "$BACKUP_DIR/config.dae.$ts"
	[ -f "$DRAFT" ] && cp -p "$DRAFT" "$BACKUP_DIR/config-draft.dae.$ts"
	echo "$ts" > "$BACKUP_DIR/latest"
}

apply() {
	local staged="$STAGE_ROOT/config.dae.new" staged2="$STAGE_ROOT/config-draft.dae.new"
	mkdir -p "$STAGE_ROOT"
	rewrite_config "$CFG" "$staged" || { echo render_failed; return 1; }
	if [ -f "$DRAFT" ]; then
		rewrite_config "$DRAFT" "$staged2" || { echo render_draft_failed; return 1; }
	else
		cp "$staged" "$staged2"
	fi
	validate "$staged" || { echo validate_failed; rm -f "$staged" "$staged2"; return 1; }
	backup
	mv -f "$staged" "$CFG" || { echo install_failed; return 1; }
	mv -f "$staged2" "$DRAFT" 2>/dev/null || :
	chmod 0600 "$CFG" 2>/dev/null || :

	local pid
	pid=$(pgrep -f 'honk-core' 2>/dev/null | head -1)
	if [ -n "$pid" ] && kill -HUP "$pid" 2>/dev/null; then
		log "dns settings applied, reloaded pid $pid"; echo "applied_reloaded"
	else
		log "dns settings applied; honk not running"; echo "applied_no_reload"
	fi
	return 0
}

preview() { echo "=== upstream ==="; render_upstreams; echo "=== rules ==="; render_rules; }

status() {
	local pid running rules=0
	pid=$(pgrep -f 'honk-core' 2>/dev/null | head -1)
	[ -n "$pid" ] && running=true || running=false
	if grep -q "$RL_BEGIN" "$CFG" 2>/dev/null; then
		# count only user qname rules (exclude default qtype guards)
		rules=$(awk '/HONK-DNS-MANAGED-BEGIN/{f=1;next}/HONK-DNS-MANAGED-END/{f=0}f&&/qname\(/{n++}END{print n+0}' "$CFG")
	fi
	echo "running=$running rules=$rules pid=${pid:-} enabled=$(get enabled)"
}

rollback() {
	local ts src
	ts=$(cat "$BACKUP_DIR/latest" 2>/dev/null)
	[ -n "$ts" ] || { echo no_backup; return 1; }
	src="$BACKUP_DIR/config.dae.$ts"
	[ -f "$src" ] || { echo backup_missing; return 1; }
	cp -p "$src" "$CFG" || { echo restore_failed; return 1; }
	[ -f "$BACKUP_DIR/config-draft.dae.$ts" ] && cp -p "$BACKUP_DIR/config-draft.dae.$ts" "$DRAFT" 2>/dev/null
	local pid; pid=$(pgrep -f 'honk-core' 2>/dev/null | head -1)
	[ -n "$pid" ] && kill -HUP "$pid" 2>/dev/null || :
	echo rolled_back
}

case "${1:-}" in
	apply)    apply ;;
	preview)  preview ;;
	status)   status ;;
	rollback) rollback ;;
	validate) [ -f "$2" ] && validate "$2" && echo valid || echo invalid ;;
	*) echo "usage: $0 apply|preview|status|rollback|validate <file>" >&2; exit 2 ;;
esac
